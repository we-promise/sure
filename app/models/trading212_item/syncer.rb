class Trading212Item::Syncer
  include SyncStats::Collector

  attr_reader :trading212_item

  def initialize(trading212_item)
    @trading212_item = trading212_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("trading212_items.sync.status.checking_credentials")) if sync.respond_to?(:status_text)
    unless trading212_item.credentials_configured?
      trading212_item.update!(status: :requires_update)
      raise Provider::Trading212::ConfigurationError, "Trading 212 API key is missing."
    end

    sync.update!(status_text: I18n.t("trading212_items.sync.status.importing_account")) if sync.respond_to?(:status_text)
    trading212_item.import_latest_data

    sync.update!(status_text: I18n.t("trading212_items.sync.status.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: trading212_item.trading212_accounts.to_a)

    unlinked_accounts = trading212_item.trading212_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = trading212_item.trading212_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      trading212_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("trading212_items.sync.status.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      trading212_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: I18n.t("trading212_items.sync.status.processing_activity")) if sync.respond_to?(:status_text)
      trading212_item.process_accounts

      sync.update!(status_text: I18n.t("trading212_items.sync.status.calculating_balances")) if sync.respond_to?(:status_text)
      trading212_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account).filter_map { |pa| pa.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "trading212") if account_ids.any?
      collect_trades_stats(sync, account_ids: account_ids, source: "trading212") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    collect_health_stats(sync, errors: nil)
  rescue Provider::Trading212::AuthenticationError, Provider::Trading212::ConfigurationError => e
    trading212_item.update!(status: :requires_update)
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
      trading212_item.trading212_accounts.sum { |acct| Array(acct.raw_positions_payload).size }
    end
end
