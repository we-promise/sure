# frozen_string_literal: true

class FioItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  # Error carrying the structured per-stage sync errors for health reporting.
  class SyncError < StandardError
    attr_reader :sync_errors

    def initialize(message, sync_errors:)
      super(message)
      @sync_errors = sync_errors
    end
  end

  attr_reader :fio_item

  def initialize(fio_item)
    @fio_item = fio_item
  end

  # Run the full sync: import, account setup detection, transaction processing, balance
  # sync scheduling, and stats/health collection. Raises on failures.
  def perform_sync(sync)
    sync.update!(status_text: I18n.t("fio_item.sync.status.importing")) if sync.respond_to?(:status_text)
    import_result = fio_item.import_latest_fio_data
    raise_if_failed_result!(import_result, stage: "Fio import")

    sync.update!(status_text: I18n.t("fio_item.sync.status.checking_setup")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: fio_item.fio_accounts)

    linked_accounts = fio_item.fio_accounts.joins(:account_provider)
    unlinked_accounts = fio_item.fio_accounts.needs_setup

    if unlinked_accounts.any?
      fio_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("fio_item.sync.status.needs_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      fio_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: I18n.t("fio_item.sync.status.processing")) if sync.respond_to?(:status_text)
      mark_import_started(sync)
      process_results = fio_item.process_accounts
      raise_if_failed_results!(process_results, stage: "Fio account processing")

      sync.update!(status_text: I18n.t("fio_item.sync.status.calculating")) if sync.respond_to?(:status_text)
      schedule_results = fio_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      raise_if_failed_results!(schedule_results, stage: "Fio account sync scheduling")

      account_ids = linked_accounts.includes(:account_provider).filter_map { |fa| fa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "fio")
    else
      Rails.logger.info "FioItem::Syncer - No linked accounts to process"
    end

    collect_health_stats(sync, errors: nil)
  rescue SyncError => e
    collect_health_stats(sync, errors: e.sync_errors)
    raise
  rescue => e
    safe_message = I18n.t("fio_item.errors.sync_failed")
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Unexpected sync error",
      source: self.class.name,
      provider_key: "fio",
      family: fio_item.family,
      metadata: { fio_item_id: fio_item.id, error_class: e.class.name, error_message: e.message }
    )
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError.new(safe_message), cause: nil
  end

  # Post-sync hook (no work required for Fio).
  def perform_post_sync
    # no-op
  end

  private

    # Raise a SyncError if a single result hash indicates failure.
    def raise_if_failed_result!(result, stage:)
      return unless failed_result?(result)

      errors = errors_from_result(result, stage: stage)
      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    # Raise a SyncError if any result in the collection indicates failure.
    def raise_if_failed_results!(results, stage:)
      errors = Array(results).filter_map do |result|
        next unless failed_result?(result)

        errors_from_result(result, stage: stage).first
      end

      return if errors.empty?

      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    # True when +result+ is a hash explicitly flagged success: false.
    def failed_result?(result)
      result.is_a?(Hash) && result.with_indifferent_access[:success] == false
    end

    # Normalize a failed result into an array of { message:, category: } errors.
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

    # Join the error messages into a single stage summary string.
    def error_message(stage, errors)
      messages = errors.map { |error| error[:message] || error["message"] }.compact
      messages.presence&.join(", ") || "#{stage} failed"
    end

    # Extract a human-readable message from a heterogeneous error value.
    def error_message_value(error)
      return error[:message].presence || error["message"].presence || error[:error].presence || error["error"].presence if error.is_a?(Hash)

      error.to_s.presence
    end
end
