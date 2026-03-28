class KrakenItem::Syncer
  include SyncStats::Collector

  attr_reader :kraken_item

  def initialize(kraken_item)
    @kraken_item = kraken_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("kraken_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless kraken_item.credentials_configured?
      error_message = I18n.t("kraken_item.syncer.credentials_invalid")
      kraken_item.update!(status: :requires_update)
      mark_failed(sync, error_message)
      return
    end

    sync.update!(status_text: I18n.t("kraken_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    kraken_item.import_latest_kraken_data

    sync.update!(status_text: I18n.t("kraken_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: kraken_item.kraken_accounts.to_a)

    unlinked_accounts = kraken_item.kraken_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = kraken_item.kraken_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      kraken_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("kraken_item.syncer.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      kraken_item.update!(pending_account_setup: false)
    end

    return unless linked_accounts.any?

    sync.update!(status_text: I18n.t("kraken_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
    kraken_item.process_accounts

    sync.update!(status_text: I18n.t("kraken_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
    kraken_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    account_ids = linked_accounts.map { |account| account.current_account&.id }.compact
    collect_transaction_stats(sync, account_ids: account_ids, source: "kraken") if account_ids.any?
  end

  def perform_post_sync
  end

  private

    def mark_failed(sync, error_message)
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("KrakenItem::Syncer#mark_failed called after completion: #{error_message}")
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
