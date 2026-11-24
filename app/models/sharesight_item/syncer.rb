class SharesightItem::Syncer
  include SyncStats::Collector

  attr_reader :sharesight_item

  def initialize(sharesight_item)
    @sharesight_item = sharesight_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("sharesight_items.sync.status.checking_credentials")) if sync.respond_to?(:status_text)
    unless sharesight_item.credentials_configured?
      sharesight_item.update!(status: :requires_update)
      raise Provider::Sharesight::ConfigurationError, "Sharesight API client is missing."
    end

    sync.update!(status_text: I18n.t("sharesight_items.sync.status.importing_portfolios")) if sync.respond_to?(:status_text)
    sharesight_item.import_latest_data

    sync.update!(status_text: I18n.t("sharesight_items.sync.status.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: sharesight_item.sharesight_accounts.to_a)

    unlinked_accounts = sharesight_item.unlinked_sharesight_accounts
    linked_accounts = sharesight_item.sharesight_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      sharesight_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("sharesight_items.sync.status.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      sharesight_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: I18n.t("sharesight_items.sync.status.processing_activity")) if sync.respond_to?(:status_text)
      results = sharesight_item.process_accounts
      collect_notices(sync, results)

      sync.update!(status_text: I18n.t("sharesight_items.sync.status.calculating_balances")) if sync.respond_to?(:status_text)
      sharesight_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account).filter_map { |sa| sa.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "sharesight") if account_ids.any?
      collect_trades_stats(sync, account_ids: account_ids, source: "sharesight") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    collect_health_stats(sync, errors: nil)
  rescue Provider::Sharesight::AuthenticationError, Provider::Sharesight::ConfigurationError => e
    sharesight_item.update!(status: :requires_update)
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
      sharesight_item.linked_sharesight_accounts.sum { |sa| Array(sa.raw_holdings_payload).size }
    end

    # Shows settlements still missing from the bank feed, and units the trades
    # don't add up to, in the connection's sync summary.
    def collect_notices(sync, results)
      notices = Array(results).flat_map { |result| Array(result.dig(:result, :notices)) if result[:success] }.compact
      return if notices.empty?

      collect_data_quality_stats(
        sync,
        warnings: notices.count { |notice| notice[:severity] == "warning" },
        details: notices
      )
    end
end
