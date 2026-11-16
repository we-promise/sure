# Syncs one Lunch Flow connection: import, count linked and unlinked accounts,
# process the linked ones and schedule their balance syncs. Status text and
# errors come from `lunchflow_items.syncer.*`, in the same shape as the
# provider kit's shared syncer.
class LunchflowItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  attr_reader :lunchflow_item

  def initialize(lunchflow_item)
    @lunchflow_item = lunchflow_item
  end

  def perform_sync(sync)
    sync_errors = []

    # Phase 1: Import data from the Lunch Flow API
    update_status(sync, :importing_accounts)
    import_result = lunchflow_item.import_latest_lunchflow_data(sync_start_date: sync.window_start_date)
    sync_errors.concat(import_result_errors(import_result))

    # Phase 2: Collect setup statistics
    update_status(sync, :checking_account_configuration)

    linked_count = lunchflow_item.lunchflow_accounts.joins(:account_provider).count
    unlinked_count = lunchflow_item.lunchflow_accounts
                                   .left_joins(:account_provider)
                                   .where(account_providers: { id: nil })
                                   .count
    total_count = linked_count + unlinked_count
    collect_provider_setup_stats(
      sync,
      total_count: total_count,
      linked_count: linked_count,
      unlinked_count: unlinked_count
    )

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_count.positive?
      lunchflow_item.update!(pending_account_setup: true)
      update_status(sync, :accounts_need_setup, count: unlinked_count)
    else
      lunchflow_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions and holdings for linked accounts only
    if linked_count.positive?
      linked_accounts = lunchflow_item.lunchflow_accounts.joins(:account_provider)
      update_status(sync, :processing_transactions)
      mark_import_started(sync)
      Rails.logger.info "#{self.class.name} - Processing #{linked_count} linked accounts"
      process_results = lunchflow_item.process_accounts
      sync_errors.concat(result_failure_errors(process_results, category: :account_processing_error, message_key: :account_processing_failed))
      Rails.logger.info "#{self.class.name} - Finished processing accounts"

      # Warn about limited investment data for investment/crypto accounts
      collect_investment_data_quality_warning(sync, linked_accounts)

      # Phase 4: Schedule balance calculations for linked accounts
      update_status(sync, :calculating_balances)
      schedule_results = lunchflow_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      sync_errors.concat(result_failure_errors(schedule_results, category: :account_sync_error, message_key: :account_sync_failed))

      # Phase 5: Collect transaction statistics
      account_ids = linked_accounts
                    .includes(account_provider: :account)
                    .filter_map { |provider_account| provider_account.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "lunchflow")
    else
      Rails.logger.info "#{self.class.name} - No linked accounts to process"
    end

    # Mark sync health
    collect_health_stats(sync, errors: sync_errors.presence)
  rescue => e
    safe_message = user_safe_error_message(e)
    Rails.logger.error "#{self.class.name} - sync failed for #{lunchflow_item.class.name} #{lunchflow_item.id}: #{e.class} - #{e.message}"
    Rails.logger.error Array(e.backtrace).first(10).join("\n")
    Sentry.capture_exception(e) do |scope|
      scope.set_tags(lunchflow_item_id: lunchflow_item.id)
    end
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError, safe_message
  end

  def perform_post_sync
    # no-op
  end

  private

    def update_status(sync, key, **options)
      return unless sync.respond_to?(:status_text)

      sync.update!(status_text: I18n.t("lunchflow_items.syncer.#{key}", **options))
    end

    def collect_provider_setup_stats(sync, total_count:, linked_count:, unlinked_count:)
      return {} unless sync.respond_to?(:sync_stats)

      setup_stats = {
        "total_accounts" => total_count,
        "linked_accounts" => linked_count,
        "unlinked_accounts" => unlinked_count
      }

      merge_sync_stats(sync, setup_stats)
      setup_stats
    end

    def import_result_errors(result)
      return [] if result.is_a?(Hash) && result[:success]

      unless result.is_a?(Hash)
        return [ sync_error(:import_error, :import_failed) ]
      end

      errors = []
      accounts_failed = result[:accounts_failed].to_i
      transactions_failed = result[:transactions_failed].to_i

      errors << sync_error(:account_import_error, :accounts_failed, count: accounts_failed) if accounts_failed.positive?
      errors << sync_error(:transaction_import_error, :transactions_failed, count: transactions_failed) if transactions_failed.positive?
      if errors.empty?
        errors << (result[:error].present? ? sync_error(:import_error, :import_failed_with_error, error: result[:error]) : sync_error(:import_error, :import_failed))
      end
      errors
    end

    def result_failure_errors(results, category:, message_key:)
      failed_count = Array(results).count { |result| result.is_a?(Hash) && result[:success] == false }
      return [] unless failed_count.positive?

      [ sync_error(category, message_key, count: failed_count) ]
    end

    def sync_error(category, message_key, **options)
      {
        message: I18n.t("lunchflow_items.syncer.#{message_key}", **options),
        category: category.to_s
      }
    end

    def user_safe_error_message(error)
      key = credentials_error?(error) ? :credentials_invalid : :failed
      I18n.t("lunchflow_items.syncer.#{key}")
    end

    def credentials_error?(error)
      error.is_a?(Provider::Lunchflow::LunchflowError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
    end

    # Collects a data quality warning if any linked accounts are investment or crypto accounts.
    # Lunchflow cannot provide activity labels (Buy, Sell, Dividend, etc.) for investment transactions,
    # which may affect budget accuracy.
    def collect_investment_data_quality_warning(sync, linked_lunchflow_accounts)
      investment_accounts = linked_lunchflow_accounts.select do |la|
        account = la.current_account
        account&.accountable_type.in?(%w[Investment Crypto])
      end

      return if investment_accounts.empty?

      collect_data_quality_stats(sync,
        warnings: investment_accounts.size,
        details: [ {
          message: I18n.t("provider_warnings.limited_investment_data"),
          severity: "warning"
        } ]
      )
    end
end
