# frozen_string_literal: true

class WiseItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  attr_reader :wise_item

  def initialize(wise_item)
    @wise_item = wise_item
  end

  def perform_sync(sync)
    sync_errors = []

    # Phase 1: Import balances and transactions from Wise API
    update_status(sync, :importing_accounts)
    import_result = wise_item.import_latest_wise_data(sync_start_date: sync.window_start_date)
    sync_errors.concat(import_result_errors(import_result))

    # Phase 2: Collect setup statistics
    update_status(sync, :checking_account_configuration)

    linked_count = wise_item.linked_accounts_count
    unlinked_count = wise_item.unlinked_accounts_count
    total_count = linked_count + unlinked_count

    collect_wise_setup_stats(sync, total_count: total_count, linked_count: linked_count, unlinked_count: unlinked_count)

    if unlinked_count.positive?
      wise_item.update!(pending_account_setup: true)
      update_status(sync, :accounts_need_setup, count: unlinked_count)
    else
      wise_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts
    if linked_count.positive?
      update_status(sync, :processing_transactions)
      mark_import_started(sync)
      process_results = wise_item.process_accounts
      sync_errors.concat(result_failure_errors(process_results, category: :account_processing_error, message_key: :account_processing_failed))

      wise_item.link_jar_transfers!

      # Phase 4: Schedule balance calculations
      update_status(sync, :calculating_balances)
      schedule_results = wise_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      sync_errors.concat(result_failure_errors(schedule_results, category: :account_sync_error, message_key: :account_sync_failed))

      # Phase 5: Collect transaction statistics
      account_ids = wise_item.wise_accounts
                             .joins(:account_provider)
                             .includes(account_provider: :account)
                             .filter_map { |wa| wa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "wise")
    end

    collect_health_stats(sync, errors: sync_errors.presence)
  rescue => e
    safe_message = user_safe_error_message(e)
    Rails.logger.error "WiseItem::Syncer - sync failed for item #{wise_item.id}: #{e.class} - #{e.message}"
    Rails.logger.error Array(e.backtrace).first(10).join("\n")
    Sentry.capture_exception(e) { |s| s.set_tags(wise_item_id: wise_item.id) }
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError, safe_message
  end

  def perform_post_sync
    # no-op
  end

  private

    def update_status(sync, key, **options)
      return unless sync.respond_to?(:status_text)

      sync.update!(status_text: I18n.t("wise_items.syncer.#{key}", **options))
    end

    def collect_wise_setup_stats(sync, total_count:, linked_count:, unlinked_count:)
      return unless sync.respond_to?(:sync_stats)

      merge_sync_stats(sync, {
        "total_accounts" => total_count,
        "linked_accounts" => linked_count,
        "unlinked_accounts" => unlinked_count
      })
    end

    def import_result_errors(result)
      return [] if result.is_a?(Hash) && result[:success]

      return [ sync_error(:import_error, :import_failed) ] unless result.is_a?(Hash)

      errors = []
      errors << sync_error(:account_import_error, :accounts_failed, count: result[:accounts_failed]) if result[:accounts_failed].to_i.positive?
      errors << sync_error(:transaction_import_error, :transactions_failed, count: result[:transactions_failed]) if result[:transactions_failed].to_i.positive?
      errors << sync_error(:import_error, :import_failed) if errors.empty?
      errors
    end

    def result_failure_errors(results, category:, message_key:)
      failed = Array(results).count { |r| r.is_a?(Hash) && r[:success] == false }
      return [] unless failed.positive?

      [ sync_error(category, message_key, count: failed) ]
    end

    def sync_error(category, message_key, **options)
      {
        message: I18n.t("wise_items.syncer.#{message_key}", **options),
        category: category.to_s
      }
    end

    def user_safe_error_message(error)
      if error.is_a?(Provider::Wise::WiseError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
        I18n.t("wise_items.syncer.credentials_invalid")
      else
        I18n.t("wise_items.syncer.failed")
      end
    end
end
