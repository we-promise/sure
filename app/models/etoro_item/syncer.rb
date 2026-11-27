class EtoroItem::Syncer
  include SyncStats::Collector

  attr_reader :etoro_item

  def initialize(etoro_item)
    @etoro_item = etoro_item
  end

  def perform_sync(sync)
    @credentials = credentials
    sync.update!(status_text: I18n.t("etoro_items.sync.status.checking_credentials")) if sync.respond_to?(:status_text)
    unless etoro_item.credentials_configured?
      etoro_item.update!(status: :requires_update)
      raise Provider::Etoro::ConfigurationError, "eToro API key is missing."
    end

    sync.update!(status_text: I18n.t("etoro_items.sync.status.importing_account")) if sync.respond_to?(:status_text)
    import_result = etoro_item.import_latest_data || {}
    sync_errors = partial_fetch_errors(import_result)

    sync.update!(status_text: I18n.t("etoro_items.sync.status.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: etoro_item.etoro_accounts.to_a)

    unlinked_accounts = etoro_item.etoro_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = etoro_item.etoro_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      etoro_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("etoro_items.sync.status.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      etoro_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: I18n.t("etoro_items.sync.status.processing_activity")) if sync.respond_to?(:status_text)
      process_results = etoro_item.process_accounts

      sync.update!(status_text: I18n.t("etoro_items.sync.status.calculating_balances")) if sync.respond_to?(:status_text)
      schedule_results = etoro_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      sync_errors += account_errors(process_results, schedule_results)

      account_ids = linked_accounts.includes(:account).filter_map { |pa| pa.account&.id }
      collect_trades_stats(sync, account_ids: account_ids, source: "etoro") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: imported_holdings(process_results), label: "processed")
    end

    rate_limited_at = import_result[:rate_limited_at]
    collect_health_stats(sync, errors: sync_errors.presence, rate_limited: rate_limited_at.present?, rate_limited_at: rate_limited_at)
  rescue Provider::Etoro::AuthenticationError, Provider::Etoro::ConfigurationError => e
    mark_requires_update!
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    def credentials
      [ etoro_item.api_key, etoro_item.user_key ]
    end

    # The keys a sync was started with may have been replaced while it ran,
    # and the new ones are good until a sync of their own says otherwise.
    def mark_requires_update!
      etoro_item.with_lock do
        etoro_item.update!(status: :requires_update) if credentials == @credentials
      end
    end

    # History and metadata eToro failed to send, kept from the last sync.
    def partial_fetch_errors(import_result)
      Array(import_result[:partial_failures]).map do |failure|
        {
          name: I18n.t("etoro_items.sync.partial_failures.#{failure[:what]}"),
          message: failure[:message],
          category: "partial_fetch"
        }
      end
    end

    def account_errors(process_results, schedule_results)
      failed_records = processed_count(process_results, :failed_records)

      errors = [ *process_results, *schedule_results ].filter_map do |result|
        { message: result[:error], category: "sync_error" } unless result[:success]
      end
      errors << { message: I18n.t("etoro_items.sync.errors.records_failed", count: failed_records), category: "sync_error" } if failed_records.positive?
      errors
    end

    def imported_holdings(process_results)
      processed_count(process_results, :holdings)
    end

    # A total over EtoroAccount::Processor#process results.
    def processed_count(process_results, key)
      Array(process_results).sum do |result|
        counts = result[:result]
        counts.is_a?(Hash) ? counts[key].to_i : 0
      end
    end
end
