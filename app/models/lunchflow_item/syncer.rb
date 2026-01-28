class LunchflowItem::Syncer
  include SyncStats::Collector

  attr_reader :lunchflow_item

  def initialize(lunchflow_item)
    @lunchflow_item = lunchflow_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Lunchflow API
    sync.update!(status_text: "Importing accounts from Lunchflow...") if sync.respond_to?(:status_text)
    lunchflow_item.import_latest_lunchflow_data

    # Phase 2: Collect setup statistics using shared concern
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: lunchflow_item.lunchflow_accounts)

    # Check for unlinked accounts
    linked_accounts = lunchflow_item.lunchflow_accounts.joins(:account_provider)
    unlinked_accounts = lunchflow_item.lunchflow_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      lunchflow_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      lunchflow_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions and holdings for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions and holdings...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      Rails.logger.info "LunchflowItem::Syncer - Processing #{linked_accounts.count} linked accounts"
      lunchflow_item.process_accounts
      Rails.logger.info "LunchflowItem::Syncer - Finished processing accounts"

      # Warn about limited investment data for investment/crypto accounts
      collect_investment_data_quality_warning(sync, linked_accounts)

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      lunchflow_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect transaction statistics
      account_ids = linked_accounts.includes(:account_provider).filter_map { |la| la.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "lunchflow")
    else
      Rails.logger.info "LunchflowItem::Syncer - No linked accounts to process"
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end

  private

    # Collects a data quality warning if any linked accounts are investment or crypto accounts.
    # Lunchflow cannot provide activity labels (Buy, Sell, Dividend, etc.) for investment transactions,
    # which may affect budget accuracy.
    def collect_investment_data_quality_warning(sync, linked_lunchflow_accounts)
      investment_accounts = linked_lunchflow_accounts.select do |la|
        account = la.current_account
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
end
