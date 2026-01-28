class SimplefinItem::Syncer
  include SyncStats::Collector

  attr_reader :simplefin_item

  def initialize(simplefin_item)
    @simplefin_item = simplefin_item
  end

  def perform_sync(sync)
    # If no accounts are linked yet, run a balances-only discovery pass so the user
    # can review and manually link accounts first. This mirrors the historical flow
    # users expect: initial 7-day balances snapshot, then full chunked history after linking.
    begin
      # Check for linked accounts via BOTH legacy FK (accounts.simplefin_account_id) AND
      # the new AccountProvider system. An account is "linked" if either association exists.
      total_linked = simplefin_item.simplefin_accounts.count { |sfa| sfa.current_account.present? }

      if total_linked == 0
        sync.update!(status_text: "Discovering accounts (balances only)...") if sync.respond_to?(:status_text)
        # Pre-mark the sync as balances_only for runtime only (no persistence)
        begin
          sync.define_singleton_method(:balances_only?) { true }
        rescue => e
          Rails.logger.warn("SimplefinItem::Syncer: failed to attach balances_only? flag: #{e.class} - #{e.message}")
        end
        SimplefinItem::Importer.new(simplefin_item, simplefin_provider: simplefin_item.simplefin_provider, sync: sync).import_balances_only
        finalize_setup_counts(sync)
        mark_completed(sync)
        return
      end
    rescue => e
      # If discovery-only path errors, fall back to regular logic below so we don't block syncs entirely
      Rails.logger.warn("SimplefinItem::Syncer auto balances-only path failed: #{e.class} - #{e.message}")
    end

    # Balances-only fast path
    if sync.respond_to?(:balances_only?) && sync.balances_only?
      sync.update!(status_text: "Refreshing balances only...") if sync.respond_to?(:status_text)
      begin
        # Use the Importer to run balances-only path
        SimplefinItem::Importer.new(simplefin_item, simplefin_provider: simplefin_item.simplefin_provider, sync: sync).import_balances_only
        # IMPORTANT: Do NOT update last_synced_at during balances-only runs.
        # Leaving last_synced_at nil ensures the next full sync uses the
        # chunked-history path to fetch full historical transactions.
        finalize_setup_counts(sync)
        mark_completed(sync)
      rescue => e
        mark_failed(sync, e)
      end
      return
    end

    # Full sync path
    sync.update!(status_text: "Importing accounts from SimpleFin...") if sync.respond_to?(:status_text)
    simplefin_item.import_latest_simplefin_data(sync: sync)

    finalize_setup_counts(sync)

    # Process transactions/holdings only for linked accounts
    # Check both legacy FK and AccountProvider associations
    linked_simplefin_accounts = simplefin_item.simplefin_accounts.select { |sfa| sfa.current_account.present? }
    if linked_simplefin_accounts.any?
      sync.update!(status_text: "Processing transactions and holdings...") if sync.respond_to?(:status_text)
      skipped_entries = simplefin_item.process_accounts

      # Collect skip stats for protected entries (user-modified, import-locked, etc.)
      if skipped_entries.any?
        collect_skip_stats(sync, skipped_entries: skipped_entries)
      end

      # Warn about limited investment data for investment/crypto accounts
      collect_investment_data_quality_warning(sync, linked_simplefin_accounts)

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      simplefin_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    mark_completed(sync)
  end

  # Public: called by Sync after finalization; keep no-op
  def perform_post_sync
    # no-op
  end

  private
    def finalize_setup_counts(sync)
      sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
      total_accounts = simplefin_item.simplefin_accounts.count

      # Count linked accounts using both legacy FK and AccountProvider associations
      linked_count = simplefin_item.simplefin_accounts.count { |sfa| sfa.current_account.present? }

      # Unlinked = no legacy FK AND no AccountProvider
      unlinked_accounts = simplefin_item.simplefin_accounts
        .left_joins(:account, :account_provider)
        .where(accounts: { id: nil }, account_providers: { id: nil })

      if unlinked_accounts.any?
        simplefin_item.update!(pending_account_setup: true)
        sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
      else
        simplefin_item.update!(pending_account_setup: false)
      end

      if sync.respond_to?(:sync_stats)
        existing = (sync.sync_stats || {})
        setup_stats = {
          "total_accounts" => total_accounts,
          "linked_accounts" => linked_count,
          "unlinked_accounts" => unlinked_accounts.count
        }
        sync.update!(sync_stats: existing.merge(setup_stats))
      end
    end

    def mark_completed(sync)
      if sync.may_start?
        sync.start!
      end
      if sync.may_complete?
        sync.complete!
      else
        # If aasm not used, at least set status text
        sync.update!(status: :completed) if sync.status != "completed"
      end

      # After completion, compute and persist compact post-run stats for the summary panel
      begin
        post_stats = compute_post_run_stats(sync)
        if post_stats.present?
          existing = (sync.sync_stats || {})
          sync.update!(sync_stats: existing.merge(post_stats))
        end
      rescue => e
        Rails.logger.warn("SimplefinItem::Syncer#mark_completed stats error: #{e.class} - #{e.message}")
      end

      # If all recorded errors are duplicate-skips, do not surface a generic failure message
      begin
        stats = (sync.sync_stats || {})
        errors = Array(stats["errors"]).map { |e| (e.is_a?(Hash) ? e["message"] || e[:message] : e.to_s) }
        if errors.present? && errors.all? { |m| m.to_s.downcase.include?("duplicate upstream account detected") }
          sync.update_columns(error: nil) if sync.respond_to?(:error)
          # Provide a gentle status hint instead
          if sync.respond_to?(:status_text)
            sync.update_columns(status_text: "Some accounts skipped as duplicates — try Link existing accounts to merge.")
          end
        end
      rescue => e
        Rails.logger.warn("SimplefinItem::Syncer duplicate-only error normalization failed: #{e.class} - #{e.message}")
      end

      # Bump item freshness timestamp (guard column existence and skip for balances-only)
      if simplefin_item.has_attribute?(:last_synced_at) && !(sync.sync_stats || {})["balances_only"].present?
        simplefin_item.update!(last_synced_at: Time.current)
      end

      # Broadcast UI updates so Providers/Accounts pages refresh without manual reload
      begin
        # Replace the SimpleFin card
        card_html = ApplicationController.render(
          partial: "simplefin_items/simplefin_item",
          formats: [ :html ],
          locals: { simplefin_item: simplefin_item }
        )
        target_id = ActionView::RecordIdentifier.dom_id(simplefin_item)
        Turbo::StreamsChannel.broadcast_replace_to(simplefin_item.family, target: target_id, html: card_html)

        # Also refresh the Manual Accounts group so duplicates clear without a full page reload
        begin
          manual_accounts = simplefin_item.family.accounts
            .visible_manual
            .order(:name)
          if manual_accounts.any?
            manual_html = ApplicationController.render(
              partial: "accounts/index/manual_accounts",
              formats: [ :html ],
              locals: { accounts: manual_accounts }
            )
            Turbo::StreamsChannel.broadcast_update_to(simplefin_item.family, target: "manual-accounts", html: manual_html)
          else
            manual_html = ApplicationController.render(inline: '<div id="manual-accounts"></div>')
            Turbo::StreamsChannel.broadcast_replace_to(simplefin_item.family, target: "manual-accounts", html: manual_html)
          end
        rescue => inner
          Rails.logger.warn("SimplefinItem::Syncer manual-accounts broadcast failed: #{inner.class} - #{inner.message}")
        end

        # Intentionally do not broadcast modal reloads here to avoid unexpected auto-pop after sync.
        # Modal opening is controlled explicitly via controller redirects with actionable conditions.
      rescue => e
        Rails.logger.warn("SimplefinItem::Syncer broadcast failed: #{e.class} - #{e.message}")
      end
    end

    # Computes transaction/holding counters between sync start and completion
    def compute_post_run_stats(sync)
      window_start = sync.created_at || 30.minutes.ago
      window_end   = Time.current

      # Get account IDs via BOTH legacy FK and AccountProvider to ensure we capture all linked accounts
      account_ids = simplefin_item.simplefin_accounts.filter_map { |sfa| sfa.current_account&.id }
      return {} if account_ids.empty?

      tx_scope = Entry.where(account_id: account_ids, source: "simplefin", entryable_type: "Transaction")
      tx_imported = tx_scope.where(created_at: window_start..window_end).count
      tx_updated  = tx_scope.where(updated_at: window_start..window_end).where.not(created_at: window_start..window_end).count
      tx_seen     = tx_imported + tx_updated

      # Count holdings from raw_holdings_payload (what the sync found) rather than
      # the database. Holdings are applied asynchronously via SimplefinHoldingsApplyJob,
      # so database counts would always be 0 at this point.
      holdings_found = simplefin_item.simplefin_accounts.sum { |sfa| Array(sfa.raw_holdings_payload).size }

      {
        "tx_imported" => tx_imported,
        "tx_updated" => tx_updated,
        "tx_seen" => tx_seen,
        "holdings_found" => holdings_found,
        "window_start" => window_start,
        "window_end" => window_end
      }
    end

    # Collects a data quality warning if any linked accounts are investment or crypto accounts.
    # SimpleFIN cannot provide activity labels (Buy, Sell, Dividend, etc.) for investment transactions,
    # which may affect budget accuracy.
    def collect_investment_data_quality_warning(sync, linked_simplefin_accounts)
      investment_accounts = linked_simplefin_accounts.select do |sfa|
        account = sfa.current_account
        account&.accountable_type.in?(%w[Investment Crypto])
      end

      return if investment_accounts.empty?

      collect_data_quality_stats(sync,
        warnings: investment_accounts.size,
        details: [ {
          message: I18n.t("provider_warnings.limited_investment_data"),
          severity: "warning"
        } ]
      )
    end

    def mark_failed(sync, error)
      # If already completed, do not attempt to fail to avoid AASM InvalidTransition
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("SimplefinItem::Syncer#mark_failed called after completion: #{error.class} - #{error.message}")
        return
      end
      if sync.may_start?
        sync.start!
      end
      if sync.may_fail?
        sync.fail!
      else
        # Avoid forcing failed if transitions are not allowed
        sync.update!(status: :failed) if !sync.respond_to?(:aasm) || sync.status.to_s != "failed"
      end
      sync.update!(error: error.message) if sync.respond_to?(:error)
    end
end
