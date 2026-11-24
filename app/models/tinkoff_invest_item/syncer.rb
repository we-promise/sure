class TinkoffInvestItem::Syncer
  include SyncStats::Collector

  attr_reader :tinkoff_invest_item

  def initialize(tinkoff_invest_item)
    @tinkoff_invest_item = tinkoff_invest_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("tinkoff_invest_items.sync.status.checking_credentials")) if sync.respond_to?(:status_text)
    unless tinkoff_invest_item.credentials_configured?
      tinkoff_invest_item.update!(status: :requires_update)
      raise Provider::TinkoffInvest::PortfolioClient::ConfigurationError, "T-Invest API token is missing."
    end

    sync.update!(status_text: I18n.t("tinkoff_invest_items.sync.status.importing_accounts")) if sync.respond_to?(:status_text)
    tinkoff_invest_item.import_latest_data

    sync.update!(status_text: I18n.t("tinkoff_invest_items.sync.status.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: tinkoff_invest_item.tinkoff_invest_accounts.to_a)

    unlinked_accounts = tinkoff_invest_item.unlinked_tinkoff_invest_accounts
    linked_accounts = tinkoff_invest_item.tinkoff_invest_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      tinkoff_invest_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("tinkoff_invest_items.sync.status.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      tinkoff_invest_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: I18n.t("tinkoff_invest_items.sync.status.processing_activity")) if sync.respond_to?(:status_text)
      tinkoff_invest_item.process_accounts

      sync.update!(status_text: I18n.t("tinkoff_invest_items.sync.status.calculating_balances")) if sync.respond_to?(:status_text)
      tinkoff_invest_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account).filter_map { |ta| ta.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "tinkoff_invest") if account_ids.any?
      collect_trades_stats(sync, account_ids: account_ids, source: "tinkoff_invest") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    collect_health_stats(sync, errors: nil)
  rescue Provider::TinkoffInvest::PortfolioClient::AuthenticationError,
         Provider::TinkoffInvest::PortfolioClient::ConfigurationError => e
    tinkoff_invest_item.update!(status: :requires_update)
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
      tinkoff_invest_item.linked_tinkoff_invest_accounts.sum do |acct|
        Array(acct.raw_portfolio_payload&.dig("positions")).count do |pos|
          pos["instrumentType"].to_s.downcase.delete_prefix("instrument_type_") != "currency"
        end
      end
    end
end
