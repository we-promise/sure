class TradeRepublicItem::Syncer
  include SyncStats::Collector

  attr_reader :trade_republic_item

  def initialize(trade_republic_item)
    @trade_republic_item = trade_republic_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("trade_republic_items.sync.status.checking_credentials")) if sync.respond_to?(:status_text)
    unless trade_republic_item.credentials_configured?
      trade_republic_item.update!(status: :requires_update)
      raise Provider::TradeRepublicClient::ConfigurationError,
        I18n.t("trade_republic_items.sync.errors.phone_number_missing")
    end
    unless trade_republic_item.ready_for_sync?
      trade_republic_item.update!(status: :requires_update)
      raise Provider::TradeRepublicClient::AuthenticationRequired,
        I18n.t("trade_republic_items.sync.errors.reauthentication_required")
    end

    sync.update!(status_text: I18n.t("trade_republic_items.sync.status.importing_account")) if sync.respond_to?(:status_text)
    trade_republic_item.import_latest_data
    collect_trade_republic_quality_stats(sync)

    sync.update!(status_text: I18n.t("trade_republic_items.sync.status.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: trade_republic_item.trade_republic_accounts.to_a)

    unlinked_accounts = trade_republic_item.trade_republic_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = trade_republic_item.trade_republic_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      trade_republic_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("trade_republic_items.sync.status.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      trade_republic_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: I18n.t("trade_republic_items.sync.status.processing_activity")) if sync.respond_to?(:status_text)
      process_results = trade_republic_item.process_accounts
      raise_if_failed_results!(process_results, stage: "Trade Republic account processing")

      sync.update!(status_text: I18n.t("trade_republic_items.sync.status.calculating_balances")) if sync.respond_to?(:status_text)
      schedule_results = trade_republic_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      raise_if_failed_results!(schedule_results, stage: "Trade Republic account sync scheduling")

      account_ids = linked_accounts.includes(:account).filter_map { |pa| pa.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "trade_republic") if account_ids.any?
      collect_trades_stats(sync, account_ids: account_ids, source: "trade_republic") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    collect_trade_republic_reconciliation_stats(sync)

    collect_health_stats(sync, errors: nil)
  rescue Provider::TradeRepublicClient::AuthenticationRequired,
         Provider::TradeRepublicClient::LoginExpired,
         Provider::TradeRepublicClient::ConfigurationError => e
    trade_republic_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue Provider::TradeRepublicClient::Error => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "provider_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    def raise_if_failed_results!(results, stage:)
      failed = Array(results).select { |result| result.is_a?(Hash) && result[:success] == false }
      return if failed.empty?

      messages = failed.filter_map { |result| result[:error].presence }
      raise Provider::TradeRepublicClient::ProviderUnavailable,
        "#{stage} failed: #{messages.presence&.join(", ") || "unknown error"}"
    end

    def count_holdings
      trade_republic_item.trade_republic_accounts.sum { |acct| Array(acct.raw_positions_payload).size }
    end

    def collect_trade_republic_quality_stats(sync)
      stats = trade_republic_item.data_quality_summary
      merge_sync_stats(sync, {
        "tr_positions" => stats[:positions],
        "tr_unpriced_positions" => stats[:unpriced_positions],
        "tr_events" => stats[:events],
        "tr_unknown_events" => stats[:unknown_events]
      })
    end

    def collect_trade_republic_reconciliation_stats(sync)
      checks = trade_republic_item.reconciliation_summary
      merge_sync_stats(sync, {
        "tr_reconciled_accounts" => checks.count { |check| check[:reconciled] },
        "tr_reconciliation_accounts" => checks.size,
        "tr_reconciliation_difference" => checks.sum(BigDecimal("0")) { |check| check[:difference] }.to_s("F")
      })
    end
end
