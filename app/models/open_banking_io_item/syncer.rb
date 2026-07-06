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

  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from open-banking.io...") if sync.respond_to?(:status_text)
    import_result = open_banking_io_item.import_latest_open_banking_io_data
    raise_if_failed_result!(import_result, stage: "open-banking.io import")

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: open_banking_io_item.open_banking_io_accounts)

    linked_accounts = open_banking_io_item.open_banking_io_accounts.joins(:account_provider)
    unlinked_accounts = open_banking_io_item.open_banking_io_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    if unlinked_accounts.any?
      open_banking_io_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      open_banking_io_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      process_results = open_banking_io_item.process_accounts
      raise_if_failed_results!(process_results, stage: "open-banking.io account processing")

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      schedule_results = open_banking_io_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      raise_if_failed_results!(schedule_results, stage: "open-banking.io account sync scheduling")

      account_ids = linked_accounts.includes(:account_provider).filter_map { |aa| aa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "open_banking_io")
    else
      Rails.logger.info "OpenBankingIoItem::Syncer - No linked accounts to process"
    end

    collect_health_stats(sync, errors: nil)
  rescue SyncError => e
    collect_health_stats(sync, errors: e.sync_errors)
    raise
  rescue => e
    safe_message = I18n.t("open_banking_io_item.errors.sync_failed")
    Rails.logger.error "OpenBankingIoItem::Syncer - Unexpected sync error: #{e.class}"
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

    def raise_if_failed_results!(results, stage:)
      errors = Array(results).filter_map do |result|
        next unless failed_result?(result)

        errors_from_result(result, stage: stage).first
      end

      return if errors.empty?

      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    def failed_result?(result)
      result.is_a?(Hash) && result.with_indifferent_access[:success] == false
    end

    def errors_from_result(result, stage:)
      data = result.with_indifferent_access
      messages = []
      messages << data[:error] if data[:error].present?
      messages << "#{data[:accounts_failed]} accounts failed" if data[:accounts_failed].to_i.positive?
      messages << "#{data[:transactions_failed]} transactions failed" if data[:transactions_failed].to_i.positive?
      messages.concat(Array(data[:errors]).map { |error| error_message_value(error) }.compact)
      messages << "#{stage} failed" if messages.empty?

      messages.map { |message| { message: "#{stage}: #{message}", category: "sync_error" } }
    end

    def error_message(stage, errors)
      messages = errors.map { |error| error[:message] || error["message"] }.compact
      messages.presence&.join(", ") || "#{stage} failed"
    end

    def error_message_value(error)
      return error[:message].presence || error["message"].presence || error[:error].presence || error["error"].presence if error.is_a?(Hash)

      error.to_s.presence
    end
end
