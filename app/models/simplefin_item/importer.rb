require "set"
class SimplefinItem::Importer
  include SimplefinNumericHelpers
  class RateLimitedError < StandardError; end
  attr_reader :simplefin_item, :simplefin_provider, :sync

  def initialize(simplefin_item, simplefin_provider:, sync: nil)
    @simplefin_item = simplefin_item
    @simplefin_provider = simplefin_provider
    @sync = sync
    @enqueued_holdings_job_ids = Set.new
    @reconciled_account_ids = Set.new  # Debounce pending reconciliation per run
  end

  def import
    Rails.logger.info "SimplefinItem::Importer - Starting import for item #{simplefin_item.id}"
    Rails.logger.info "SimplefinItem::Importer - last_synced_at: #{simplefin_item.last_synced_at.inspect}"
    Rails.logger.info "SimplefinItem::Importer - sync_start_date: #{simplefin_item.sync_start_date.inspect}"

    # Clear stale error and reconciliation stats from previous syncs at the start of a full import
    # This ensures the UI doesn't show outdated warnings from old sync runs
    if sync.respond_to?(:sync_stats)
      sync.update_columns(sync_stats: {
        "cleared_at" => Time.current.iso8601,
        "import_started" => true
      })
    end

    begin
      # Defensive guard: If last_synced_at is set but there are linked accounts
      # with no transactions captured yet (typical after a balances-only run),
      # force the first full run to use chunked history to backfill.
      #
      # Check for linked accounts via BOTH legacy FK (accounts.simplefin_account_id) AND
      # the new AccountProvider system. An account is "linked" if either association exists.
      linked_accounts = simplefin_item.simplefin_accounts.select { |sfa| sfa.current_account.present? }
      no_txns_yet = linked_accounts.any? && linked_accounts.all? { |sfa| sfa.raw_transactions_payload.blank? }

      if simplefin_item.last_synced_at.nil? || no_txns_yet
        # First sync (or balances-only pre-run) — use chunked approach to get full history
        Rails.logger.info "SimplefinItem::Importer - Using CHUNKED HISTORY import (last_synced_at=#{simplefin_item.last_synced_at.inspect}, no_txns_yet=#{no_txns_yet})"
        import_with_chunked_history
      else
        # Regular sync - use single request with buffer
        Rails.logger.info "SimplefinItem::Importer - Using REGULAR SYNC (last_synced_at=#{simplefin_item.last_synced_at&.strftime('%Y-%m-%d %H:%M')})"
        import_regular_sync
      end
    rescue RateLimitedError => e
      stats["rate_limited"] = true
      stats["rate_limited_at"] = Time.current.iso8601
      persist_stats!
      raise e
    end
  end

  # Balances-only import: discover accounts and update account balances without transactions/holdings
  def import_balances_only
    Rails.logger.info "SimplefinItem::Importer - Balances-only import for item #{simplefin_item.id}"
    stats["balances_only"] = true

    # Fetch accounts without date filters
    accounts_data = fetch_accounts_data(start_date: nil)
    return if accounts_data.nil?

    # Store snapshot for observability
    simplefin_item.upsert_simplefin_snapshot!(accounts_data)

    # Update counts (set to discovered for this run rather than accumulating)
    discovered = accounts_data[:accounts]&.size.to_i
    stats["total_accounts"] = discovered
    persist_stats!

    # Upsert SimpleFin accounts minimal attributes and update linked Account balances
    accounts_data[:accounts].to_a.each do |account_data|
      begin
        import_account_minimal_and_balance(account_data)
      rescue => e
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        cat = classify_error(e)
        register_error(message: e.message, category: cat, account_id: account_data[:id], name: account_data[:name])
      ensure
        persist_stats!
      end
    end
  end

  private

    # Minimal upsert and balance update for balances-only mode
    def import_account_minimal_and_balance(account_data)
      account_id = account_data[:id].to_s
      return if account_id.blank?

      sfa = simplefin_item.simplefin_accounts.find_or_initialize_by(account_id: account_id)
      sfa.assign_attributes(
        name: account_data[:name],
        account_type: (account_data["type"].presence || account_data[:type].presence || sfa.account_type.presence || "unknown"),
        currency: (account_data[:currency].presence || account_data["currency"].presence || sfa.currency.presence || sfa.current_account&.currency.presence || simplefin_item.family&.currency.presence || "USD"),
        current_balance: account_data[:balance],
        available_balance: account_data[:"available-balance"],
        balance_date: (account_data["balance-date"] || account_data[:"balance-date"]),
        raw_payload: account_data,
        org_data: account_data[:org]
      )
      begin
        sfa.save!
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Surface a friendly duplicate/validation signal in sync stats and continue
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        msg = e.message.to_s
        if msg.downcase.include?("already been taken") || msg.downcase.include?("unique")
          msg = "Duplicate upstream account detected for SimpleFin (account_id=#{account_id}). Try relinking to an existing manual account."
        end
        register_error(message: msg, category: "other", account_id: account_id, name: account_data[:name])
        persist_stats!
        return
      end
      # In pre-prompt balances-only discovery, do NOT auto-create provider-linked accounts.
      # Only update balance for already-linked accounts (if any), to avoid creating duplicates in setup.
      if (acct = sfa.current_account)
        adapter = Account::ProviderImportAdapter.new(acct)

        # Normalize balances for SimpleFIN liabilities so immediate UI is correct after discovery
        bal   = to_decimal(account_data[:balance])
        avail = to_decimal(account_data[:"available-balance"])
        observed = bal.nonzero? ? bal : avail

        is_linked_liability = [ "CreditCard", "Loan" ].include?(acct.accountable_type)
        inferred = begin
          Simplefin::AccountTypeMapper.infer(
            name: account_data[:name],
            holdings: account_data[:holdings],
            extra: account_data[:extra],
            balance: bal,
            available_balance: avail,
            institution: account_data.dig(:org, :name)
          )
        rescue
          nil
        end
        is_mapper_liability = inferred && [ "CreditCard", "Loan" ].include?(inferred.accountable_type)
        is_liability = is_linked_liability || is_mapper_liability

        normalized = observed
        if is_liability
          # Try the overpayment analyzer first (feature-flagged)
          begin
            result = SimplefinAccount::Liabilities::OverpaymentAnalyzer
              .new(sfa, observed_balance: observed)
              .call

            case result.classification
            when :credit
              normalized = -observed.abs
            when :debt
              normalized = observed.abs
            else
              # Fallback to existing normalization when unknown/disabled
              begin
                obs = {
                  reason: result.reason,
                  tx_count: result.metrics[:tx_count],
                  charges_total: result.metrics[:charges_total],
                  payments_total: result.metrics[:payments_total],
                  observed: observed.to_s("F")
                }.compact
                Rails.logger.info("SimpleFIN overpayment heuristic (balances-only): unknown; falling back #{obs.inspect}")
              rescue
                # no-op
              end
              both_present = bal.nonzero? && avail.nonzero?
              if both_present && same_sign?(bal, avail)
                if bal.positive? && avail.positive?
                  normalized = -observed.abs
                elsif bal.negative? && avail.negative?
                  normalized = observed.abs
                end
              else
                normalized = -observed
              end
            end
          rescue NameError
            # Analyzer missing; use legacy path
            both_present = bal.nonzero? && avail.nonzero?
            if both_present && same_sign?(bal, avail)
              if bal.positive? && avail.positive?
                normalized = -observed.abs
              elsif bal.negative? && avail.negative?
                normalized = observed.abs
              end
            else
              normalized = -observed
            end
          end
        end

        cash = if acct.accountable_type == "Investment"
          # Leave investment cash to investment calculators in full run
          normalized
        else
          normalized
        end

        adapter.update_balance(
          balance: account_data[:balance],
          cash_balance: account_data[:"available-balance"],
          source: "simplefin"
        )
      end
    end
    def stats
      @stats ||= {}
    end

    # Heuristics to set a SimpleFIN account inactive when upstream indicates closure/hidden
    # or when we repeatedly observe zero balances and zero holdings. This should not block
    # import and only sets a flag and suggestion via sync stats.
    def update_inactive_state(simplefin_account, account_data)
      payload = (account_data || {}).with_indifferent_access
      raw = (simplefin_account.raw_payload || {}).with_indifferent_access

      # Flags from payloads
      closed = [ payload[:closed], payload[:hidden], payload.dig(:extra, :closed), raw[:closed], raw[:hidden] ].compact.any? { |v| v == true || v.to_s == "true" }

      balance = payload[:balance]
      avail = payload[:"available-balance"]
      holdings = payload[:holdings]
      amounts = [ balance, avail ].compact
      zeroish_balance = amounts.any? && amounts.all? { |x| x.to_d.zero? rescue false }
      no_holdings = !(holdings.is_a?(Array) && holdings.any?)

      stats["zero_runs"] ||= {}
      stats["inactive"] ||= {}
      key = simplefin_account.account_id.presence || simplefin_account.id
      key = key.to_s
      # Ensure key exists and defaults to false (so tests don't read nil)
      stats["inactive"][key] = false unless stats["inactive"].key?(key)

      if closed
        stats["inactive"][key] = true
        stats["hints"] = Array(stats["hints"]) + [ "Some accounts appear closed/hidden upstream. You can relink or hide them." ]
        return
      end

      # Skip zero balance detection for liability accounts (CreditCard, Loan) where
      # 0 balance with no holdings is normal (paid off card/loan)
      account_type = simplefin_account.current_account&.accountable_type
      return if %w[CreditCard Loan].include?(account_type)

      # Only count each account once per sync run to avoid false positives during
      # chunked imports (which process the same account multiple times)
      zero_balance_seen_keys << key if zeroish_balance && no_holdings
      return if zero_balance_seen_keys.count(key) > 1

      if zeroish_balance && no_holdings
        stats["zero_runs"][key] = stats["zero_runs"][key].to_i + 1
        # Cap to avoid unbounded growth
        stats["zero_runs"][key] = [ stats["zero_runs"][key], 10 ].min
      else
        stats["zero_runs"][key] = 0
        stats["inactive"][key] = false
      end

      if stats["zero_runs"][key].to_i >= 3
        stats["inactive"][key] = true
        stats["hints"] = Array(stats["hints"]) + [ "One or more accounts show no balance/holdings for multiple syncs — consider relinking or marking inactive." ]
      end
    end

    # Track accounts that have been flagged for zero balance in this sync run
    def zero_balance_seen_keys
      @zero_balance_seen_keys ||= []
    end

    # Track seen error fingerprints during a single importer run to avoid double counting
    def seen_errors
      @seen_errors ||= Set.new
    end

    # Register an error into stats with de-duplication and bucketing
    def register_error(message:, category:, account_id: nil, name: nil)
      msg = message.to_s.strip
      cat = (category.presence || "other").to_s
      fp = [ account_id.to_s.presence, cat, msg ].compact.join("|")
      first_time = !seen_errors.include?(fp)
      seen_errors.add(fp)

      if first_time
        Rails.logger.warn(
          "SimpleFin sync error (unique this run): category=#{cat} account_id=#{account_id.inspect} name=#{name.inspect} msg=#{msg}"
        )
        # Emit an instrumentation event for observability dashboards
        ActiveSupport::Notifications.instrument(
          "simplefin.error",
          item_id: simplefin_item.id,
          account_id: account_id,
          account_name: name,
          category: cat,
          message: msg
        )
      else
        # Keep logs tame; don't spam on repeats in the same run
      end

      stats["errors"] ||= []
      buckets = stats["error_buckets"] ||= { "auth" => 0, "api" => 0, "network" => 0, "other" => 0 }
      if first_time
        stats["total_errors"] = stats.fetch("total_errors", 0) + 1
        buckets[cat] = buckets.fetch(cat, 0) + 1
      end

      # Maintain a small rolling sample (not de-duped so users can see most recent context)
      stats["errors"] << { account_id: account_id, name: name, message: msg, category: cat }
      stats["errors"] = stats["errors"].last(5)
      persist_stats!
    end

    def persist_stats!
      return unless sync && sync.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged) # avoid callbacks/validations during tight loops
    end

    def import_with_chunked_history
      # SimpleFin's actual limit is 60 days (not 365 as documented)
      # Use 60-day chunks to stay within limits
      chunk_size_days = 60
      max_requests = 22
      current_end_date = Time.current

      # Decide how far back to walk:
      # - If the user set a custom sync_start_date, honor it
      # - Else, for first-time chunked history, walk back up to the provider-safe
      #   limit implied by chunking so we actually import meaningful history.
      #   We do NOT use the small initial lookback (7 days) here, because that
      #   would clip the very first chunk to ~1 week and prevent further history.
      user_start_date = simplefin_item.sync_start_date
      implied_max_lookback_days = chunk_size_days * max_requests
      default_start_date = implied_max_lookback_days.days.ago
      target_start_date = user_start_date ? user_start_date.beginning_of_day : default_start_date

      # Enforce maximum 3-year lookback to respect SimpleFin's actual 60-day limit per request
      # With 22 requests max: 60 days × 22 = 1,320 days = 3.6 years, so 3 years is safe
      max_lookback_date = 3.years.ago.beginning_of_day
      if target_start_date < max_lookback_date
        Rails.logger.info "SimpleFin: Limiting sync start date from #{target_start_date.strftime('%Y-%m-%d')} to #{max_lookback_date.strftime('%Y-%m-%d')} due to rate limits"
        target_start_date = max_lookback_date
      end

      # Pre-step: Unbounded discovery to ensure we see all accounts even if the
      # chunked window would otherwise filter out newly added, inactive accounts.
      perform_account_discovery

      total_accounts_imported = 0
      chunk_count = 0

      Rails.logger.info "SimpleFin chunked sync: syncing from #{target_start_date.strftime('%Y-%m-%d')} to #{current_end_date.strftime('%Y-%m-%d')}"

      # Walk backwards from current_end_date in proper chunks
      chunk_end_date = current_end_date

      while chunk_count < max_requests && chunk_end_date > target_start_date
        chunk_count += 1

        # Calculate chunk start date - always use exactly chunk_size_days to stay within limits
        chunk_start_date = chunk_end_date - chunk_size_days.days

        # Don't go back further than the target start date
        if chunk_start_date < target_start_date
          chunk_start_date = target_start_date
        end

        # Verify we're within SimpleFin's limits
        actual_days = (chunk_end_date.to_date - chunk_start_date.to_date).to_i
        if actual_days > 365
          Rails.logger.error "SimpleFin: Chunk exceeds 365 days (#{actual_days} days). This should not happen."
          chunk_start_date = chunk_end_date - 365.days
        end

        Rails.logger.info "SimpleFin chunked sync: fetching chunk #{chunk_count}/#{max_requests} (#{chunk_start_date.strftime('%Y-%m-%d')} to #{chunk_end_date.strftime('%Y-%m-%d')}) - #{actual_days} days"

        accounts_data = fetch_accounts_data(start_date: chunk_start_date, end_date: chunk_end_date)
        return if accounts_data.nil? # Error already handled

        # Store raw payload on first chunk only
        if chunk_count == 1
          simplefin_item.upsert_simplefin_snapshot!(accounts_data)
        end

        # Tally accounts returned for stats
        chunk_accounts = accounts_data[:accounts]&.size.to_i
        total_accounts_imported += chunk_accounts
        # Treat total as max unique accounts seen this run, not per-chunk accumulation
        stats["total_accounts"] = [ stats["total_accounts"].to_i, chunk_accounts ].max

        # Import accounts and transactions for this chunk with per-account error skipping
        accounts_data[:accounts]&.each do |account_data|
          begin
            import_account(account_data)
          rescue => e
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            # Collect lightweight error info for UI stats
            cat = classify_error(e)
            begin
              register_error(message: e.message.to_s, category: cat, account_id: account_data[:id], name: account_data[:name])
            rescue
              # no-op if account_data is missing keys
            end
            Rails.logger.warn("SimpleFin: Skipping account due to error: #{e.class} - #{e.message}")
          ensure
            persist_stats!
          end
        end

        # Stop if we've reached our target start date
        if chunk_start_date <= target_start_date
          Rails.logger.info "SimpleFin chunked sync: reached target start date, stopping"
          break
        end

        # Continue to next chunk - move the end date backwards
        chunk_end_date = chunk_start_date
      end

      Rails.logger.info "SimpleFin chunked sync completed: #{chunk_count} chunks processed, #{total_accounts_imported} account records imported"
    end

    def import_regular_sync
      perform_account_discovery

      # Step 2: Fetch transactions/holdings using the regular window.
      # Note: Don't pass explicit `pending:` here - let fetch_accounts_data use the
      # SIMPLEFIN_INCLUDE_PENDING config. This allows users to disable pending transactions
      # if their bank's SimpleFIN integration produces duplicates when pending→posted.
      start_date = determine_sync_start_date
      Rails.logger.info "SimplefinItem::Importer - import_regular_sync: last_synced_at=#{simplefin_item.last_synced_at&.strftime('%Y-%m-%d %H:%M')} => start_date=#{start_date&.strftime('%Y-%m-%d')}"
      accounts_data = fetch_accounts_data(start_date: start_date)
      return if accounts_data.nil? # Error already handled

      # Store raw payload
      simplefin_item.upsert_simplefin_snapshot!(accounts_data)

      # Tally accounts for stats
      count = accounts_data[:accounts]&.size.to_i
      # Treat total as max unique accounts seen this run, not accumulation
      stats["total_accounts"] = [ stats["total_accounts"].to_i, count ].max

      # Import accounts (merges transactions/holdings into existing rows), skipping failures per-account
      accounts_data[:accounts]&.each do |account_data|
        begin
          import_account(account_data)
        rescue => e
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          cat = classify_error(e)
          begin
            register_error(message: e.message.to_s, category: cat, account_id: account_data[:id], name: account_data[:name])
          rescue
            # no-op if account_data is missing keys
          end
          Rails.logger.warn("SimpleFin: Skipping account during regular sync due to error: #{e.class} - #{e.message}")
        ensure
          persist_stats!
        end
      end
    end

    #
    # Performs discovery of accounts in an unbounded way so providers that
    # filter by date windows cannot hide newly created upstream accounts.
    #
    # Steps:
    # - Request `/accounts` without dates; count results
    # - If zero, retry with `pending: true` (some bridges only reveal new/pending)
    # - If any accounts are returned, upsert a snapshot and import each account
    #
    # Returns nothing; side-effects are snapshot + account upserts.
    def perform_account_discovery
      Rails.logger.info "SimplefinItem::Importer - perform_account_discovery START (no date params - transactions may be empty)"
      discovery_data = fetch_accounts_data(start_date: nil)
      discovered_count = discovery_data&.dig(:accounts)&.size.to_i
      Rails.logger.info "SimpleFin discovery (no params) returned #{discovered_count} accounts"

      if discovered_count.zero?
        discovery_data = fetch_accounts_data(start_date: nil, pending: true)
        discovered_count = discovery_data&.dig(:accounts)&.size.to_i
        Rails.logger.info "SimpleFin discovery (pending=1) returned #{discovered_count} accounts"
      end

      if discovery_data && discovered_count > 0
        simplefin_item.upsert_simplefin_snapshot!(discovery_data)
        # Treat total as max unique accounts seen this run, not accumulation
        stats["total_accounts"] = [ stats["total_accounts"].to_i, discovered_count ].max
        discovery_data[:accounts]&.each do |account_data|
          begin
            import_account(account_data)
          rescue => e
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            cat = classify_error(e)
            begin
              register_error(message: e.message.to_s, category: cat, account_id: account_data[:id], name: account_data[:name])
            rescue
              # no-op if account_data is missing keys
            end
            Rails.logger.warn("SimpleFin discovery: Skipping account due to error: #{e.class} - #{e.message}")
          ensure
            persist_stats!
          end
        end

        # Clean up orphaned SimplefinAccount records whose account_id no longer exists upstream.
        # This handles the case where a user deletes and re-adds an institution in SimpleFIN,
        # which generates new account IDs. Without this cleanup, both old (stale) and new
        # SimplefinAccount records would appear in the setup UI as duplicates.
        upstream_account_ids = discovery_data[:accounts].map { |a| a[:id].to_s }.compact
        prune_orphaned_simplefin_accounts(upstream_account_ids)
      end
    end

    # Removes SimplefinAccount records that no longer exist upstream and are not linked to any Account.
    # This prevents duplicate accounts from appearing in the setup UI after a user re-adds an
    # institution in SimpleFIN (which generates new account IDs).
    def prune_orphaned_simplefin_accounts(upstream_account_ids)
      return if upstream_account_ids.blank?

      # Find SimplefinAccount records with account_ids NOT in the upstream set
      # Eager-load associations to prevent N+1 queries when checking linkage
      orphaned = simplefin_item.simplefin_accounts
        .includes(:account, :account_provider)
        .where.not(account_id: upstream_account_ids)
        .where.not(account_id: nil)

      orphaned.each do |sfa|
        # Only delete if not linked to any Account (via legacy FK or AccountProvider)
        # Note: sfa.account checks the legacy FK on Account.simplefin_account_id
        #       sfa.account_provider checks the new AccountProvider join table
        linked_via_legacy = sfa.account.present?
        linked_via_provider = sfa.account_provider.present?

        if !linked_via_legacy && !linked_via_provider
          Rails.logger.info "SimpleFin: Pruning orphaned SimplefinAccount id=#{sfa.id} account_id=#{sfa.account_id} (no longer exists upstream)"
          stats["accounts_pruned"] = stats.fetch("accounts_pruned", 0) + 1
          sfa.destroy
        else
          Rails.logger.info "SimpleFin: Keeping stale SimplefinAccount id=#{sfa.id} account_id=#{sfa.account_id} (still linked to Account)"
        end
      end

      persist_stats! if stats["accounts_pruned"].to_i > 0
    end

    # Fetches accounts (and optionally transactions/holdings) from SimpleFin.
    #
    # Params:
    # - start_date: Date or nil — when provided, provider may filter by date window
    # - end_date:   Date or nil — optional end of window
    # - pending:    Boolean or nil — when true, ask provider to include pending/new
    #
    # Returns a Hash payload with keys like :accounts, or nil when an error is
    # handled internally via `handle_errors`.
    def fetch_accounts_data(start_date:, end_date: nil, pending: nil)
      # Determine whether to include pending based on explicit arg, env var, or Setting.
      # Priority: explicit arg > env var > Setting (allows runtime changes via UI)
      effective_pending = if !pending.nil?
        pending
      elsif ENV["SIMPLEFIN_INCLUDE_PENDING"].present?
        Rails.configuration.x.simplefin.include_pending
      else
        Setting.syncs_include_pending
      end

      # Debug logging to track exactly what's being sent to SimpleFin API
      start_str = start_date.respond_to?(:strftime) ? start_date.strftime("%Y-%m-%d") : "none"
      end_str = end_date.respond_to?(:strftime) ? end_date.strftime("%Y-%m-%d") : "current"
      days_requested = if start_date && end_date
        (end_date.to_date - start_date.to_date).to_i
      else
        "unknown"
      end
      Rails.logger.info "SimplefinItem::Importer - API Request: #{start_str} to #{end_str} (#{days_requested} days) pending=#{effective_pending ? 1 : 0}"

      begin
        # Track API request count for quota awareness
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        accounts_data = simplefin_provider.get_accounts(
          simplefin_item.access_url,
          start_date: start_date,
          end_date: end_date,
          pending: effective_pending
        )
        # Soft warning when approaching SimpleFin daily refresh guidance
        if stats["api_requests"].to_i >= 20
          stats["rate_limit_warning"] = true
        end
      rescue Provider::Simplefin::SimplefinError => e
        # Handle authentication errors by marking item as requiring update
        if e.error_type == :access_forbidden
          simplefin_item.update!(status: :requires_update)
          raise e
        else
          raise e
        end
      end

      # Optional raw payload debug logging (guarded by ENV to avoid spam)
      if Rails.configuration.x.simplefin.debug_raw
        Rails.logger.debug("SimpleFIN raw: #{accounts_data.inspect}")
      end

      # Handle errors if present in response
      if accounts_data[:errors] && accounts_data[:errors].any?
        if accounts_data[:accounts].to_a.any?
          # Partial failure: record errors for visibility but continue processing accounts
          record_errors(accounts_data[:errors])
        else
          # Global failure: no accounts were returned; treat as fatal
          handle_errors(accounts_data[:errors])
          return nil
        end
      end

      # Some servers return a top-level message/string rather than an errors array
      if accounts_data[:error].present?
        if accounts_data[:accounts].to_a.any?
          record_errors([ accounts_data[:error] ])
        else
          handle_errors([ accounts_data[:error] ])
          return nil
        end
      end

      accounts_data
    end

    def determine_sync_start_date
      # For the first sync, get only a limited amount of data to avoid SimpleFin API limits
      # SimpleFin requires a start_date parameter - without it, only returns recent transactions
      unless simplefin_item.last_synced_at
        return initial_sync_lookback_period.days.ago
      end

      # For subsequent syncs, fetch from last sync date with a buffer
      # Use buffer to ensure we don't miss any late-posting transactions
      simplefin_item.last_synced_at - sync_buffer_period.days
    end

    def import_account(account_data)
      account_id = account_data[:id].to_s

      # Validate required account_id to prevent duplicate creation
      return if account_id.blank?

      simplefin_account = simplefin_item.simplefin_accounts.find_or_initialize_by(
        account_id: account_id
      )

      # Store transactions and holdings separately from account data to avoid overwriting
      transactions = account_data[:transactions]
      holdings = account_data[:holdings]

      # Log detailed info for accounts with holdings (investment accounts) to debug missing transactions
      # Note: SimpleFIN doesn't include a 'type' field, so we detect investment accounts by presence of holdings or name
      acct_name = account_data[:name].to_s.downcase
      has_holdings = holdings.is_a?(Array) && holdings.any?
      is_investment = has_holdings || acct_name.include?("ira") || acct_name.include?("401k") || acct_name.include?("retirement") || acct_name.include?("brokerage")

      # Always log for all accounts to trace the import flow
      Rails.logger.info "SimplefinItem::Importer#import_account - account_id=#{account_id} name='#{account_data[:name]}' txn_count=#{transactions&.count || 0} holdings_count=#{holdings&.count || 0}"

      if is_investment
        Rails.logger.info "SimpleFIN Investment Account Debug - account_id=#{account_id} name='#{account_data[:name]}'"
        Rails.logger.info "  - API response keys: #{account_data.keys.inspect}"
        Rails.logger.info "  - transactions count: #{transactions&.count || 0}"
        Rails.logger.info "  - holdings count: #{holdings&.count || 0}"
        Rails.logger.info "  - existing raw_transactions_payload count: #{simplefin_account.raw_transactions_payload.to_a.count}"

        # Log transaction data
        if transactions.is_a?(Array) && transactions.any?
          Rails.logger.info "  - Transaction IDs: #{transactions.map { |t| t[:id] || t["id"] }.inspect}"
        else
          Rails.logger.warn "  - NO TRANSACTIONS in API response for investment account!"
          # Log what the transactions field actually contains
          Rails.logger.info "  - transactions raw value: #{account_data[:transactions].inspect}"
        end
      end

      # Update all attributes; only update transactions if present to avoid wiping prior data
      attrs = {
        name: account_data[:name],
        account_type: (account_data["type"].presence || account_data[:type].presence || "unknown"),
        currency: (account_data[:currency].presence || account_data["currency"].presence || simplefin_account.currency.presence || simplefin_account.current_account&.currency.presence || simplefin_item.family&.currency.presence || "USD"),
        current_balance: account_data[:balance],
        available_balance: account_data[:"available-balance"],
        balance_date: (account_data["balance-date"] || account_data[:"balance-date"]),
        raw_payload: account_data,
        org_data: account_data[:org]
      }

      # Merge transactions from chunked/regular imports (accumulate history).
      # Prefer non-pending records with a real posted timestamp over earlier
      # pending placeholders that sometimes come back with posted: 0.
      if transactions.is_a?(Array) && transactions.any?
        existing_transactions = simplefin_account.raw_transactions_payload.to_a

        Rails.logger.info "SimplefinItem::Importer#import_account - Merging transactions for account_id=#{account_id}: #{existing_transactions.count} existing + #{transactions.count} new"

        # Build a map of key => best_tx
        best_by_key = {}

        comparator = lambda do |a, b|
          ax = a.with_indifferent_access
          bx = b.with_indifferent_access

          # Key dates
          a_posted = ax[:posted].to_i
          b_posted = bx[:posted].to_i
          a_trans  = ax[:transacted_at].to_i
          b_trans  = bx[:transacted_at].to_i

          a_pending = !!ax[:pending]
          b_pending = !!bx[:pending]

          # 1) Prefer real posted date over 0/blank
          a_has_posted = a_posted > 0
          b_has_posted = b_posted > 0
          return a if a_has_posted && !b_has_posted
          return b if b_has_posted && !a_has_posted

          # 2) Prefer later posted date
          if a_posted != b_posted
            return a_posted > b_posted ? a : b
          end

          # 3) Prefer non-pending over pending
          if a_pending != b_pending
            return a_pending ? b : a
          end

          # 4) Prefer later transacted_at
          if a_trans != b_trans
            return a_trans > b_trans ? a : b
          end

          # 5) Stable: keep 'a'
          a
        end

        build_key = lambda do |tx|
          t = tx.with_indifferent_access
          t[:id] || t[:fitid] || [ t[:posted], t[:amount], t[:description] ]
        end

        (existing_transactions + transactions).each do |tx|
          key = build_key.call(tx)
          if (cur = best_by_key[key])
            best_by_key[key] = comparator.call(cur, tx)
          else
            best_by_key[key] = tx
          end
        end

        merged_transactions = best_by_key.values
        attrs[:raw_transactions_payload] = merged_transactions

        Rails.logger.info "SimplefinItem::Importer#import_account - Merged result for account_id=#{account_id}: #{merged_transactions.count} total transactions"

        # NOTE: Reconciliation disabled - it analyzes the SimpleFin API response
        # which only contains ~90 days of history, creating misleading "gap" warnings
        # that don't reflect actual database state. Re-enable if we improve it to
        # compare against database transactions instead of just the API response.
        # begin
        #   reconcile_transactions(simplefin_account, merged_transactions)
        # rescue => e
        #   Rails.logger.warn("SimpleFin: reconciliation failed for sfa=#{simplefin_account.id || account_id}: #{e.class} - #{e.message}")
        # end
      else
        Rails.logger.info "SimplefinItem::Importer#import_account - No transactions in API response for account_id=#{account_id} (transactions=#{transactions.inspect.first(100)})"
      end

      # Track whether incoming holdings are new/changed so we can materialize and refresh balances
      holdings_changed = false
      if holdings.is_a?(Array) && holdings.any?
        prior = simplefin_account.raw_holdings_payload.to_a
        if prior != holdings
          attrs[:raw_holdings_payload] = holdings
          # Also mirror into raw_payload['holdings'] so downstream calculators can use it
          raw = simplefin_account.raw_payload.is_a?(Hash) ? simplefin_account.raw_payload.deep_dup : {}
          raw = raw.with_indifferent_access
          raw[:holdings] = holdings
          attrs[:raw_payload] = raw
          holdings_changed = true
        end
      end

      simplefin_account.assign_attributes(attrs)

      # Inactive detection/toggling (non-blocking)
      begin
        update_inactive_state(simplefin_account, account_data)
      rescue => e
        Rails.logger.warn("SimpleFin: inactive-state evaluation failed for sfa=#{simplefin_account.id || account_id}: #{e.class} - #{e.message}")
      end

      # Final validation before save to prevent duplicates
      if simplefin_account.account_id.blank?
        simplefin_account.account_id = account_id
      end

      begin
        simplefin_account.save!

        # Log final state after save for debugging
        if is_investment
          Rails.logger.info "SimplefinItem::Importer#import_account - SAVED account_id=#{account_id}: raw_transactions_payload now has #{simplefin_account.reload.raw_transactions_payload.to_a.count} transactions"
        end

        # Post-save side effects
        acct = simplefin_account.current_account
        if acct
          # Handle pending transaction reconciliation (debounced per run to avoid
          # repeated scans during chunked history imports)
          unless @reconciled_account_ids.include?(acct.id)
            @reconciled_account_ids << acct.id
            reconcile_and_track_pending_duplicates(acct)
            exclude_and_track_stale_pending(acct)
            track_stale_unmatched_pending(acct)
          end

          # Refresh credit attributes when available-balance present
          if acct.accountable_type == "CreditCard" && account_data[:"available-balance"].present?
            begin
              SimplefinAccount::Liabilities::CreditProcessor.new(simplefin_account).process
            rescue => e
              Rails.logger.warn("SimpleFin: credit post-import refresh failed for sfa=#{simplefin_account.id}: #{e.class} - #{e.message}")
            end
          end

          # If holdings changed for an investment/crypto account, enqueue holdings apply job and recompute cash balance
          if holdings_changed && [ "Investment", "Crypto" ].include?(acct.accountable_type)
            # Debounce per importer run per SFA
            unless @enqueued_holdings_job_ids.include?(simplefin_account.id)
              SimplefinHoldingsApplyJob.perform_later(simplefin_account.id)
              @enqueued_holdings_job_ids << simplefin_account.id
            end

            # Recompute cash balance using existing calculator; avoid altering canonical ledger balances
            begin
              calculator = SimplefinAccount::Investments::BalanceCalculator.new(simplefin_account)
              new_cash = calculator.cash_balance
              acct.update!(cash_balance: new_cash)
            rescue => e
              Rails.logger.warn("SimpleFin: cash balance recompute failed for sfa=#{simplefin_account.id}: #{e.class} - #{e.message}")
            end
          end
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Treat duplicates/validation failures as partial success: count and surface friendly error, then continue
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        msg = e.message.to_s
        if msg.downcase.include?("already been taken") || msg.downcase.include?("unique")
          msg = "Duplicate upstream account detected for SimpleFin (account_id=#{account_id}). Try relinking to an existing manual account."
        end
        register_error(message: msg, category: "other", account_id: account_id, name: account_data[:name])
        persist_stats!
        nil
      ensure
        # Ensure stats like zero_runs/inactive are persisted even when no errors occur,
        # particularly helpful for focused unit tests that call import_account directly.
        persist_stats!
      end
    end


    # Record non-fatal provider errors into sync stats without raising, so the
    # rest of the accounts can continue to import. This is used when the
    # response contains both :accounts and :errors.
    def record_errors(errors)
      arr = Array(errors)
      return if arr.empty?

      # Determine if these errors indicate the item needs an update (e.g. 2FA)
      needs_update = arr.any? do |error|
        if error.is_a?(String)
          down = error.downcase
          down.include?("reauth") || down.include?("auth") || down.include?("two-factor") || down.include?("2fa") || down.include?("forbidden") || down.include?("unauthorized")
        else
          code = error[:code].to_s.downcase
          type = error[:type].to_s.downcase
          code.include?("auth") || code.include?("token") || type.include?("auth")
        end
      end

      if needs_update
        Rails.logger.warn("SimpleFin: marking item ##{simplefin_item.id} requires_update due to auth-related provider errors")
        simplefin_item.update!(status: :requires_update)
        ActiveSupport::Notifications.instrument(
          "simplefin.item_requires_update",
          item_id: simplefin_item.id,
          reason: "provider_errors_partial",
          count: arr.size
        )
      end

      Rails.logger.info("SimpleFin: recording #{arr.size} non-fatal provider error(s) with partial data present")
      ActiveSupport::Notifications.instrument(
        "simplefin.provider_errors",
        item_id: simplefin_item.id,
        count: arr.size
      )

      arr.each do |error|
        msg = if error.is_a?(String)
          error
        else
          error[:description] || error[:message] || error[:error] || error.to_s
        end
        down = msg.to_s.downcase
        category = if down.include?("timeout") || down.include?("timed out")
          "network"
        elsif down.include?("auth") || down.include?("reauth") || down.include?("forbidden") || down.include?("unauthorized") || down.include?("2fa") || down.include?("two-factor")
          "auth"
        elsif down.include?("429") || down.include?("rate limit")
          "api"
        else
          "other"
        end
        register_error(message: msg, category: category)
      end
    end

    def handle_errors(errors)
      error_messages = errors.map { |error| error.is_a?(String) ? error : (error[:description] || error[:message]) }.join(", ")

      # Mark item as requiring update for authentication-related errors
      needs_update = errors.any? do |error|
        if error.is_a?(String)
          error.downcase.include?("reauthenticate") || error.downcase.include?("authentication")
        else
          error[:code] == "auth_failure" || error[:code] == "token_expired" ||
          error[:type] == "authentication_error"
        end
      end

      if needs_update
        Rails.logger.warn("SimpleFin: marking item ##{simplefin_item.id} requires_update due to fatal auth error(s): #{error_messages}")
        simplefin_item.update!(status: :requires_update)
      end

      down = error_messages.downcase
      # Detect and surface rate-limit specifically with a friendlier exception
      if down.include?("make fewer requests") ||
         down.include?("only refreshed once every 24 hours") ||
         down.include?("rate limit")
        Rails.logger.info("SimpleFin: raising RateLimitedError for item ##{simplefin_item.id}: #{error_messages}")
        ActiveSupport::Notifications.instrument(
          "simplefin.rate_limited",
          item_id: simplefin_item.id,
          message: error_messages
        )
        raise RateLimitedError, "SimpleFin rate limit: data refreshes at most once every 24 hours. Try again later."
      end

      # Fall back to generic SimpleFin error classified as :api_error
      Rails.logger.error("SimpleFin fatal API error for item ##{simplefin_item.id}: #{error_messages}")
      ActiveSupport::Notifications.instrument(
        "simplefin.fatal_error",
        item_id: simplefin_item.id,
        message: error_messages
      )
      raise Provider::Simplefin::SimplefinError.new(
        "SimpleFin API errors: #{error_messages}",
        :api_error
      )
    end

    # Classify exceptions into simple buckets for UI stats
    def classify_error(e)
      msg = e.message.to_s.downcase
      klass = e.class.name.to_s
      # Avoid referencing Net::OpenTimeout/ReadTimeout constants (may not be loaded)
      is_timeout = msg.include?("timeout") || msg.include?("timed out") || klass.include?("Timeout")
      case
      when is_timeout
        "network"
      when msg.include?("auth") || msg.include?("reauth") || msg.include?("forbidden") || msg.include?("unauthorized")
        "auth"
      when msg.include?("429") || msg.include?("too many requests") || msg.include?("rate limit") || msg.include?("5xx") || msg.include?("502") || msg.include?("503") || msg.include?("504")
        "api"
      else
        "other"
      end
    end

    def initial_sync_lookback_period
      # Default to 60 days for initial sync to capture recent investment
      # transactions (dividends, contributions, etc.). Providers that support
      # deeper history will supply it via chunked fetches, and users can
      # optionally set a custom `sync_start_date` to go further back.
      60
    end

    def sync_buffer_period
      # Default to 30 days buffer for subsequent syncs
      # Investment accounts often have infrequent transactions (dividends, etc.)
      # that would be missed with a shorter window
      30
    end

    # Transaction reconciliation: detect potential data gaps or missing transactions
    # This helps identify when SimpleFin may not be returning complete data
    def reconcile_transactions(simplefin_account, new_transactions)
      return if new_transactions.blank?

      account_id = simplefin_account.account_id
      existing_transactions = simplefin_account.raw_transactions_payload.to_a
      reconciliation = { account_id: account_id, issues: [] }

      # 1. Check for unexpected transaction count drops
      # If we previously had more transactions and now have fewer (after merge),
      # something may have been removed upstream
      if existing_transactions.any?
        existing_count = existing_transactions.size
        new_count = new_transactions.size

        # After merging, we should have at least as many as before
        # A significant drop (>10%) could indicate data loss
        if new_count < existing_count
          drop_pct = ((existing_count - new_count).to_f / existing_count * 100).round(1)
          if drop_pct > 10
            reconciliation[:issues] << {
              type: "transaction_count_drop",
              message: "Transaction count dropped from #{existing_count} to #{new_count} (#{drop_pct}% decrease)",
              severity: drop_pct > 25 ? "high" : "medium"
            }
          end
        end
      end

      # 2. Detect gaps in transaction history
      # Look for periods with no transactions that seem unusual
      gaps = detect_transaction_gaps(new_transactions)
      if gaps.any?
        reconciliation[:issues] += gaps.map do |gap|
          {
            type: "transaction_gap",
            message: "No transactions between #{gap[:start_date]} and #{gap[:end_date]} (#{gap[:days]} days)",
            severity: gap[:days] > 30 ? "high" : "medium",
            gap_start: gap[:start_date],
            gap_end: gap[:end_date],
            gap_days: gap[:days]
          }
        end
      end

      # 3. Check for stale data (most recent transaction is old)
      latest_tx_date = extract_latest_transaction_date(new_transactions)
      if latest_tx_date.present?
        days_since_latest = (Date.current - latest_tx_date).to_i
        if days_since_latest > 7
          reconciliation[:issues] << {
            type: "stale_transactions",
            message: "Most recent transaction is #{days_since_latest} days old",
            severity: days_since_latest > 14 ? "high" : "medium",
            latest_date: latest_tx_date.to_s,
            days_stale: days_since_latest
          }
        end
      end

      # 4. Check for duplicate transaction IDs (data integrity issue)
      duplicate_ids = find_duplicate_transaction_ids(new_transactions)
      if duplicate_ids.any?
        reconciliation[:issues] << {
          type: "duplicate_ids",
          message: "Found #{duplicate_ids.size} duplicate transaction ID(s)",
          severity: "low",
          duplicate_count: duplicate_ids.size
        }
      end

      # Record reconciliation results in stats
      if reconciliation[:issues].any?
        stats["reconciliation"] ||= {}
        stats["reconciliation"][account_id] = reconciliation

        # Count issues by severity
        high_severity = reconciliation[:issues].count { |i| i[:severity] == "high" }
        medium_severity = reconciliation[:issues].count { |i| i[:severity] == "medium" }

        if high_severity > 0
          stats["reconciliation_warnings"] = stats.fetch("reconciliation_warnings", 0) + high_severity
          Rails.logger.warn("SimpleFin reconciliation: #{high_severity} high-severity issue(s) for account #{account_id}")

          ActiveSupport::Notifications.instrument(
            "simplefin.reconciliation_warning",
            item_id: simplefin_item.id,
            account_id: account_id,
            issues: reconciliation[:issues]
          )
        end

        if medium_severity > 0
          stats["reconciliation_notices"] = stats.fetch("reconciliation_notices", 0) + medium_severity
        end

        persist_stats!
      end

      reconciliation
    end

    # Detect gaps in transaction history (periods with no activity)
    def detect_transaction_gaps(transactions)
      return [] if transactions.blank? || transactions.size < 2

      # Extract and sort transaction dates
      dates = transactions.map do |tx|
        t = tx.with_indifferent_access
        posted = t[:posted]
        next nil if posted.blank? || posted.to_i <= 0
        Time.at(posted.to_i).to_date
      end.compact.uniq.sort

      return [] if dates.size < 2

      gaps = []
      min_gap_days = 14 # Only report gaps of 2+ weeks

      dates.each_cons(2) do |earlier, later|
        gap_days = (later - earlier).to_i
        if gap_days >= min_gap_days
          gaps << {
            start_date: earlier.to_s,
            end_date: later.to_s,
            days: gap_days
          }
        end
      end

      # Limit to top 3 largest gaps to avoid noise
      gaps.sort_by { |g| -g[:days] }.first(3)
    end

    # Extract the most recent transaction date
    def extract_latest_transaction_date(transactions)
      return nil if transactions.blank?

      latest_timestamp = transactions.map do |tx|
        t = tx.with_indifferent_access
        posted = t[:posted]
        posted.to_i if posted.present? && posted.to_i > 0
      end.compact.max

      latest_timestamp ? Time.at(latest_timestamp).to_date : nil
    end

    # Find duplicate transaction IDs
    def find_duplicate_transaction_ids(transactions)
      return [] if transactions.blank?

      ids = transactions.map do |tx|
        t = tx.with_indifferent_access
        t[:id] || t[:fitid]
      end.compact

      ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
    end

    # Reconcile pending transactions that have a matching posted version
    # Handles duplicates where pending and posted both exist (tip adjustments, etc.)
    def reconcile_and_track_pending_duplicates(account)
      reconcile_stats = Entry.reconcile_pending_duplicates(account: account, dry_run: false)

      exact_matches = reconcile_stats[:details].select { |d| d[:match_type] == "exact" }
      fuzzy_suggestions = reconcile_stats[:details].select { |d| d[:match_type] == "fuzzy_suggestion" }

      if exact_matches.any?
        stats["pending_reconciled"] = stats.fetch("pending_reconciled", 0) + exact_matches.size
        stats["pending_reconciled_details"] ||= []
        exact_matches.each do |detail|
          stats["pending_reconciled_details"] << {
            "account_name" => detail[:account],
            "pending_name" => detail[:pending_name],
            "posted_name" => detail[:posted_name]
          }
        end
        stats["pending_reconciled_details"] = stats["pending_reconciled_details"].last(50)
      end

      if fuzzy_suggestions.any?
        stats["duplicate_suggestions_created"] = stats.fetch("duplicate_suggestions_created", 0) + fuzzy_suggestions.size
        stats["duplicate_suggestions_details"] ||= []
        fuzzy_suggestions.each do |detail|
          stats["duplicate_suggestions_details"] << {
            "account_name" => detail[:account],
            "pending_name" => detail[:pending_name],
            "posted_name" => detail[:posted_name]
          }
        end
        stats["duplicate_suggestions_details"] = stats["duplicate_suggestions_details"].last(50)
      end
    rescue => e
      Rails.logger.warn("SimpleFin: pending reconciliation failed for account #{account.id}: #{e.class} - #{e.message}")
      record_reconciliation_error("pending_reconciliation", account, e)
    end

    # Auto-exclude stale pending transactions (>8 days old with no matching posted version)
    # Prevents orphaned pending transactions from affecting budgets indefinitely
    def exclude_and_track_stale_pending(account)
      excluded_count = Entry.auto_exclude_stale_pending(account: account)
      return unless excluded_count > 0

      stats["stale_pending_excluded"] = stats.fetch("stale_pending_excluded", 0) + excluded_count
      stats["stale_pending_details"] ||= []
      stats["stale_pending_details"] << {
        "account_name" => account.name,
        "account_id" => account.id,
        "count" => excluded_count
      }
      stats["stale_pending_details"] = stats["stale_pending_details"].last(50)
    rescue => e
      Rails.logger.warn("SimpleFin: stale pending cleanup failed for account #{account.id}: #{e.class} - #{e.message}")
      record_reconciliation_error("stale_pending_cleanup", account, e)
    end

    # Track stale pending transactions that couldn't be matched (for user awareness)
    # These are >8 days old, still pending, and have no duplicate suggestion
    def track_stale_unmatched_pending(account)
      stale_unmatched = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(excluded: false)
        .where("entries.date < ?", 8.days.ago.to_date)
        .where(<<~SQL.squish)
          (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
          OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
        SQL
        .where(<<~SQL.squish)
          transactions.extra -> 'potential_posted_match' IS NULL
        SQL
        .count

      return unless stale_unmatched > 0

      stats["stale_unmatched_pending"] = stats.fetch("stale_unmatched_pending", 0) + stale_unmatched
      stats["stale_unmatched_details"] ||= []
      stats["stale_unmatched_details"] << {
        "account_name" => account.name,
        "account_id" => account.id,
        "count" => stale_unmatched
      }
      stats["stale_unmatched_details"] = stats["stale_unmatched_details"].last(50)
    rescue => e
      Rails.logger.warn("SimpleFin: stale unmatched tracking failed for account #{account.id}: #{e.class} - #{e.message}")
      record_reconciliation_error("stale_unmatched_tracking", account, e)
    end

    # Record reconciliation errors to sync_stats for UI visibility
    def record_reconciliation_error(context, account, error)
      stats["reconciliation_errors"] ||= []
      stats["reconciliation_errors"] << {
        "context" => context,
        "account_id" => account.id,
        "account_name" => account.name,
        "error" => "#{error.class}: #{error.message}"
      }
      stats["reconciliation_errors"] = stats["reconciliation_errors"].last(20)
    end
end
