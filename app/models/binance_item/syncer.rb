class BinanceItem::Syncer
  include SyncStats::Collector

  attr_reader :binance_item

  def initialize(binance_item)
    @binance_item = binance_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("binance_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless binance_item.credentials_configured?
      error_message = I18n.t("binance_item.syncer.credentials_invalid")
      binance_item.update!(status: :requires_update)
      mark_failed(sync, error_message)
      return
    end

    sync.update!(status_text: I18n.t("binance_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    binance_item.import_latest_binance_data
    binance_item.update!(status: :good)

    sync.update!(status_text: I18n.t("binance_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: binance_item.binance_accounts.to_a)

    unlinked_accounts = binance_item.binance_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = binance_item.binance_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      binance_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("binance_item.syncer.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      binance_item.update!(pending_account_setup: false)
    end

    return unless linked_accounts.any?

    sync.update!(status_text: I18n.t("binance_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
    binance_item.process_accounts

    sync.update!(status_text: I18n.t("binance_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
    binance_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    account_ids = linked_accounts.map { |account| account.current_account&.id }.compact
    collect_transaction_stats(sync, account_ids: account_ids, source: "binance") if account_ids.any?
    collect_trades_stats(sync, account_ids: account_ids, source: "binance") if account_ids.any?
    collect_holdings_stats(sync, holdings_count: count_holdings(linked_accounts), label: "processed")
  rescue Provider::Binance::AuthenticationError => e
    binance_item.update!(status: :requires_update)
    mark_failed(sync, e.message)
  end

  def perform_post_sync
    # no-op
  end

  private

    def count_holdings(linked_accounts)
      linked_accounts.sum { |account| Array(account.raw_holdings_payload).size }
    end

    def mark_failed(sync, error_message)
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("BinanceItem::Syncer#mark_failed called after completion: #{error_message}")
        return
      end

      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?

      if sync.respond_to?(:may_fail?) && sync.may_fail?
        sync.fail!
      elsif sync.respond_to?(:status)
        sync.update!(status: :failed)
      end

      sync.update!(error: error_message) if sync.respond_to?(:error)
      sync.update!(status_text: error_message) if sync.respond_to?(:status_text)
    end
end
