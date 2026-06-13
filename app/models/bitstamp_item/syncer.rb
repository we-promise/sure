# frozen_string_literal: true

class BitstampItem::Syncer
  include SyncStats::Collector

  attr_reader :bitstamp_item

  def initialize(bitstamp_item)
    @bitstamp_item = bitstamp_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("bitstamp_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless bitstamp_item.credentials_configured?
      bitstamp_item.update!(status: :requires_update)
      mark_failed(sync, I18n.t("bitstamp_item.syncer.credentials_invalid"))
      return
    end

    sync.update!(status_text: I18n.t("bitstamp_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    bitstamp_item.import_latest_bitstamp_data
    bitstamp_item.update!(status: :good) if bitstamp_item.requires_update?

    sync.update!(status_text: I18n.t("bitstamp_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: bitstamp_item.bitstamp_accounts.to_a)

    unlinked = bitstamp_item.bitstamp_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked = bitstamp_item.bitstamp_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    if unlinked.any?
      bitstamp_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("bitstamp_item.syncer.accounts_need_setup", count: unlinked.count)) if sync.respond_to?(:status_text)
    else
      bitstamp_item.update!(pending_account_setup: false)
    end

    return unless linked.any?

    sync.update!(status_text: I18n.t("bitstamp_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
    bitstamp_item.process_accounts

    sync.update!(status_text: I18n.t("bitstamp_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
    bitstamp_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    account_ids = linked.map { |bitstamp_account| bitstamp_account.current_account&.id }.compact
    if account_ids.any?
      collect_transaction_stats(sync, account_ids: account_ids, source: "bitstamp")
      collect_trades_stats(sync, account_ids: account_ids, source: "bitstamp")
    end
  rescue Provider::Bitstamp::AuthenticationError, Provider::Bitstamp::PermissionError => e
    bitstamp_item.update!(status: :requires_update)
    mark_failed(sync, e.message)
    raise
  rescue StandardError => e
    Rails.logger.error "BitstampItem::Syncer - unexpected error during sync: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    mark_failed(sync, e.message)
    raise
  end

  def perform_post_sync
  end

  private

    def mark_failed(sync, error_message)
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
