class IbkrItem::Syncer
  include SyncStats::Collector

  attr_reader :ibkr_item

  def initialize(ibkr_item)
    @ibkr_item = ibkr_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Checking IBKR credentials...") if sync.respond_to?(:status_text)
    unless ibkr_item.credentials_configured?
      ibkr_item.update!(status: :requires_update)
      raise Provider::IbkrFlex::ConfigurationError, "IBKR credentials are missing."
    end

    sync.update!(status_text: "Importing IBKR accounts...") if sync.respond_to?(:status_text)
    ibkr_item.import_latest_ibkr_data

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: ibkr_item.ibkr_accounts.to_a)

    unlinked_accounts = ibkr_item.ibkr_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = ibkr_item.ibkr_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      ibkr_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} IBKR account(s) need setup...") if sync.respond_to?(:status_text)
    else
      ibkr_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing holdings and activity...") if sync.respond_to?(:status_text)
      ibkr_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      ibkr_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account).filter_map { |provider_account| provider_account.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "ibkr") if account_ids.any?
      collect_trades_stats(sync, account_ids: account_ids, source: "ibkr") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    collect_health_stats(sync, errors: nil)
  rescue Provider::IbkrFlex::AuthenticationError, Provider::IbkrFlex::ConfigurationError => e
    ibkr_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    def count_holdings
      ibkr_item.ibkr_accounts.sum { |account| Array(account.raw_holdings_payload).size }
    end
end
