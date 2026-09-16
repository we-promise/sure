class AkahuItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  class SyncError < StandardError
    attr_reader :sync_errors

    def initialize(message, sync_errors:)
      super(message)
      @sync_errors = sync_errors
    end
  end

  attr_reader :akahu_item

  def initialize(akahu_item)
    @akahu_item = akahu_item
  end

  def perform_sync(sync)
    AkahuItem::LegacyAccess.with_item(akahu_item, operation: :ingest, sync: sync) do |current, current_sync|
      unless current_sync
        raise Provider::AccountData::LegacyWriterFence::InvalidSource, "Akahu coordination requires its original Sync"
      end
      AkahuItem::LegacyAccess.assert_transport!
      self.class.new(current).send(:perform_sync_admitted, current_sync)
    end
  end

  private def perform_sync_admitted(sync)
    @item_context = AkahuItem::LegacyAccess.transport_context(akahu_item)
    update_status(sync, "Importing accounts from Akahu...")
    import_result = akahu_item.import_latest_akahu_data
    raise_if_failed_result!(import_result, stage: "Akahu import")

    update_status(sync, "Checking account configuration...")
    collect_setup_stats(sync, provider_accounts: akahu_item.akahu_accounts)

    linked_accounts = akahu_item.akahu_accounts.joins(:account_provider)
    unlinked_accounts = akahu_item.akahu_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    unlinked_count = unlinked_accounts.count
    with_progress(sync) do |current_sync, current_item|
      current_item.update!(pending_account_setup: unlinked_count.positive?)
      current_sync.update!(status_text: "#{unlinked_count} accounts need setup...") if unlinked_count.positive?
    end

    if linked_accounts.any?
      update_status(sync, "Processing transactions...")
      mark_import_started(sync)
      pending_inventories = import_result.is_a?(Hash) ? import_result.with_indifferent_access[:pending_inventories] || {} : {}
      process_results = akahu_item.process_accounts(pending_inventories: pending_inventories)
      raise_if_failed_results!(process_results, stage: "Akahu account processing")

      update_status(sync, "Calculating balances...")
      schedule_results = akahu_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      raise_if_failed_results!(schedule_results, stage: "Akahu account sync scheduling")

      account_ids = linked_accounts.includes(:account_provider).filter_map { |aa| aa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "akahu")
    else
      Rails.logger.info "AkahuItem::Syncer - No linked accounts to process"
    end

    collect_health_stats(sync, errors: nil)
  rescue *AkahuItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue SyncError => e
    collect_health_stats(sync, errors: e.sync_errors)
    raise
  rescue => e
    safe_message = I18n.t("akahu_item.errors.sync_failed")
    Rails.logger.error "AkahuItem::Syncer - Unexpected sync error: #{e.class}"
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError.new(safe_message), cause: nil
  end

  def perform_post_sync
    # no-op
  end

  private

    def update_status(sync, message)
      with_progress(sync) { |current, _item| current.update!(status_text: message) }
    end

    # The generic stats collector swallows write failures. Coordinator progress
    # must instead preserve an ownership denial and retain the fresh Sync stats.
    def merge_sync_stats(sync, new_stats)
      with_progress(sync) do |current, _item|
        current.update!(sync_stats: (current.sync_stats || {}).merge(new_stats))
      end
    end

    def with_progress(sync)
      AkahuItem::LegacyAccess.with_snapshot(akahu_item, expected_context: @item_context) do |fresh|
        current = Provider::AccountData::LegacyWriterFence.scoped_sync!(akahu_item, sync)
        current.lock!("FOR UPDATE NOWAIT")
        Provider::AccountData::LegacyWriterFence.scoped_sync!(akahu_item, current)
        yield current, fresh
      end
    rescue ActiveRecord::RecordNotFound
      raise Provider::AccountData::LegacyWriterFence::OwnershipChanged, "Akahu sync owner changed before progress publication", cause: nil
    rescue ActiveRecord::LockWaitTimeout
      raise Provider::AccountData::LegacyWriterFence::Busy, "Akahu sync progress is being changed; retry publication", cause: nil
    end

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
