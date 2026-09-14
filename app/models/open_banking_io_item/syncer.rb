class OpenBankingIoItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  class SyncError < StandardError
    attr_reader :sync_errors

    def initialize(message, sync_errors:)
      super(message)
      @sync_errors = sync_errors
    end
  end

  attr_reader :open_banking_io_item

  def initialize(open_banking_io_item)
    @open_banking_io_item = open_banking_io_item
  end

  # A PSD2 aggregator fans out over many banks, and partial failure is the steady state --
  # one connection's consent lapses every 90 days, one bank rate-limits, one account 404s
  # after a reconnect. So a failure in ONE account must never stop the others' transactions
  # becoming entries or their balances being recalculated.
  #
  # Everything that can succeed runs first; failures are collected and raised at the end so
  # the user still sees the error and the connection is still marked unhealthy.
  def perform_sync(sync)
    deferred_errors = []

    update_status_text(sync, I18n.t("open_banking_io_item.syncer.importing_accounts"))
    import_result = open_banking_io_item.import_latest_open_banking_io_data
    stage = I18n.t("open_banking_io_item.errors.stages.import")
    # A total failure (no account data at all) has nothing to process, so it still aborts.
    # A partial one carries on with whatever did arrive.
    raise_if_failed_result!(import_result, stage: stage) if total_failure?(import_result)
    deferred_errors.concat(errors_from_result(import_result, stage: stage)) if failed_result?(import_result)

    update_status_text(sync, I18n.t("open_banking_io_item.syncer.checking_configuration"))
    collect_setup_stats(sync, provider_accounts: open_banking_io_item.open_banking_io_accounts)

    linked_accounts = open_banking_io_item.open_banking_io_accounts.joins(:account_provider)
    unlinked_accounts = open_banking_io_item.open_banking_io_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    if unlinked_accounts.any?
      open_banking_io_item.update!(pending_account_setup: true)
      update_status_text(sync, I18n.t("open_banking_io_item.syncer.accounts_need_setup", count: unlinked_accounts.count))
    else
      open_banking_io_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      update_status_text(sync, I18n.t("open_banking_io_item.syncer.processing_transactions"))
      mark_import_started(sync)
      process_results = open_banking_io_item.process_accounts
      deferred_errors.concat(errors_from_results(process_results, stage: I18n.t("open_banking_io_item.errors.stages.account_processing")))

      # Runs even when an account failed above: balance materialization for the accounts
      # that DID process must not be held hostage by one that did not.
      update_status_text(sync, I18n.t("open_banking_io_item.syncer.calculating_balances"))
      schedule_results = open_banking_io_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      deferred_errors.concat(errors_from_results(schedule_results, stage: I18n.t("open_banking_io_item.errors.stages.sync_scheduling")))

      account_ids = linked_accounts.includes(:account_provider).filter_map { |aa| aa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "open_banking_io")
    else
      Rails.logger.info "OpenBankingIoItem::Syncer - No linked accounts to process"
    end

    if deferred_errors.any?
      collect_health_stats(sync, errors: deferred_errors)
      raise SyncError.new(error_message(nil, deferred_errors), sync_errors: deferred_errors)
    end

    collect_health_stats(sync, errors: nil)
  rescue SyncError => e
    collect_health_stats(sync, errors: e.sync_errors)
    raise
  rescue => e
    safe_message = I18n.t("open_banking_io_item.errors.sync_failed")
    Rails.logger.error "OpenBankingIoItem::Syncer - Unexpected sync error: #{e.class}"
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Unexpected sync error",
      source: self.class.name,
      provider_key: "open_banking_io",
      family: open_banking_io_item.family,
      metadata: { open_banking_io_item_id: open_banking_io_item.id, error_class: e.class.name, error_message: e.message }
    )
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError.new(safe_message), cause: nil
  end

  def perform_post_sync
    # no-op
  end

  private

    def raise_if_failed_result!(result, stage:)
      return unless failed_result?(result)

      errors = errors_from_result(result, stage: stage)
      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    def errors_from_results(results, stage:)
      Array(results).filter_map do |result|
        next unless failed_result?(result)

        errors_from_result(result, stage: stage).first
      end
    end

    # Nothing usable came back at all -- as opposed to some accounts failing, which the
    # caller carries on from. Importer#failed_result sets :error; partial failures only
    # bump the accounts_failed / transactions_failed counters.
    def total_failure?(result)
      failed_result?(result) && result.with_indifferent_access[:error].present?
    end

    def raise_if_failed_results!(results, stage:)
      errors = errors_from_results(results, stage: stage)

      return if errors.empty?

      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    def failed_result?(result)
      result.is_a?(Hash) && result.with_indifferent_access[:success] == false
    end

    def update_status_text(sync, text)
      sync.update!(status_text: text) if sync.respond_to?(:status_text)
    end

    def errors_from_result(result, stage:)
      data = result.with_indifferent_access
      messages = []
      messages << data[:error] if data[:error].present?
      messages << I18n.t("open_banking_io_item.errors.accounts_failed", count: data[:accounts_failed].to_i) if data[:accounts_failed].to_i.positive?
      messages << I18n.t("open_banking_io_item.errors.transactions_failed_count", count: data[:transactions_failed].to_i) if data[:transactions_failed].to_i.positive?
      messages.concat(Array(data[:errors]).map { |error| error_message_value(error) }.compact)
      messages << I18n.t("open_banking_io_item.errors.stage_failed", stage: stage) if messages.empty?

      messages.map { |message| { message: "#{stage}: #{message}", category: "sync_error" } }
    end

    def error_message(stage, errors)
      messages = errors.map { |error| error[:message] || error["message"] }.compact
      return messages.join(", ") if messages.any?
      return I18n.t("open_banking_io_item.errors.sync_failed") if stage.nil?

      I18n.t("open_banking_io_item.errors.stage_failed", stage: stage)
    end

    def error_message_value(error)
      return error[:message].presence || error["message"].presence || error[:error].presence || error["error"].presence if error.is_a?(Hash)

      error.to_s.presence
    end
end
