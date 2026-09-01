# frozen_string_literal: true

class CoinspotItem::Syncer
  include SyncStats::Collector

  attr_reader :coinspot_item

  # Initializes with the connection to sync.
  def initialize(coinspot_item)
    @coinspot_item = coinspot_item
  end

  # Drives one full sync cycle: validates credentials, imports the latest
  # CoinSpot data, tracks which discovered accounts still need setup versus
  # which are already linked, processes activity for the linked ones, and
  # schedules their balance recalculation. A credential/permission failure
  # marks the connection as needing updated credentials; any linked
  # account's processing failure fails the whole sync (rather than
  # completing "successfully" with only partial history imported) after
  # capturing the failure details to DebugLogEntry.
  def perform_sync(sync)
    sync.update!(status_text: I18n.t("coinspot_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless coinspot_item.credentials_configured?
      coinspot_item.update!(status: :requires_update)
      mark_failed(sync, I18n.t("coinspot_item.syncer.credentials_invalid"))
      return
    end

    sync.update!(status_text: I18n.t("coinspot_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    coinspot_item.import_latest_coinspot_data
    coinspot_item.update!(status: :good) if coinspot_item.requires_update?

    sync.update!(status_text: I18n.t("coinspot_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: coinspot_item.coinspot_accounts.to_a)

    unlinked = coinspot_item.coinspot_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked = coinspot_item.coinspot_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    if unlinked.any?
      coinspot_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("coinspot_item.syncer.accounts_need_setup", count: unlinked.count)) if sync.respond_to?(:status_text)
    else
      coinspot_item.update!(pending_account_setup: false)
    end

    return unless linked.any?

    sync.update!(status_text: I18n.t("coinspot_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
    process_results = coinspot_item.process_accounts
    processing_failures = process_results.select { |result| result[:success] == false }
    if processing_failures.any?
      message = I18n.t("coinspot_item.syncer.processing_failed", count: processing_failures.count)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: message,
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_item.family,
        metadata: { coinspot_item_id: coinspot_item.id, failures: processing_failures }
      )
      raise StandardError, message
    end

    sync.update!(status_text: I18n.t("coinspot_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
    coinspot_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    account_ids = linked.map { |coinspot_account| coinspot_account.current_account&.id }.compact
    if account_ids.any?
      collect_transaction_stats(sync, account_ids: account_ids, source: "coinspot")
      collect_trades_stats(sync, account_ids: account_ids, source: "coinspot")
    end
  rescue Provider::Coinspot::AuthenticationError, Provider::Coinspot::PermissionError => e
    coinspot_item.update!(status: :requires_update)
    mark_failed(sync, e.message)
    raise
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Unexpected error during CoinSpot sync: #{e.message}",
      source: self.class.name,
      provider_key: "coinspot",
      family: coinspot_item.family,
      metadata: { error_class: e.class.name, backtrace: e.backtrace&.first(5) }
    )
    mark_failed(sync, e.message)
    raise
  end

  # No follow-up work needed after a sync; required by the Syncer interface.
  def perform_post_sync
  end

  private

    # Transitions the sync record to :failed (via its state machine when
    # available) and records the error message for display.
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
