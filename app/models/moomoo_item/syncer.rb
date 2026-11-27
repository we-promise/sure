class MoomooItem::Syncer
  include SyncStats::Collector

  # Import failures that leave an account's balance and holdings as they
  # were. Any other failure only delays some history.
  ACCOUNT_FAILURES = %i[balances_and_positions].freeze

  attr_reader :moomoo_item

  def initialize(moomoo_item)
    @moomoo_item = moomoo_item
  end

  # A connection moomoo stopped accepting is flagged for reconnecting by
  # MoomooItem#with_access_token, not here.
  def perform_sync(sync)
    update_status(sync, "checking_connection")
    raise Provider::Moomoo::MoomooError.new("moomoo connection is not authorized", :not_connected) unless moomoo_item.connected?

    update_status(sync, "importing_accounts")
    import_result = moomoo_item.import_latest_data
    import_result = {} unless import_result.is_a?(Hash)
    sync_errors = import_errors(import_result)

    update_status(sync, "checking_configuration")
    collect_setup_stats(sync, provider_accounts: moomoo_item.linkable_moomoo_accounts.includes(account_provider: :account).to_a)

    unlinked_count = moomoo_item.unlinked_accounts_count
    moomoo_item.update!(pending_account_setup: unlinked_count.positive?)
    update_status(sync, "accounts_need_setup", count: unlinked_count) if unlinked_count.positive?
    notices = unlinked_currency_notices
    collect_data_quality_stats(sync, notices: notices.size, details: notices) if notices.any?

    linked_accounts = moomoo_item.moomoo_accounts.joins(:account).merge(Account.visible)
    if linked_accounts.any?
      update_status(sync, "processing_activity")
      process_results = moomoo_item.process_accounts

      update_status(sync, "calculating_balances")
      schedule_results = moomoo_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      sync_errors += account_errors(process_results, schedule_results)

      account_ids = linked_accounts.includes(:account).filter_map { |moomoo_account| moomoo_account.account&.id }
      collect_trades_stats(sync, account_ids: account_ids, source: "moomoo") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings(linked_accounts), label: "processed")
    end

    update_status(sync, "history_backfill_pending") if import_result[:backfill_pending]
    rate_limited_at = import_result[:rate_limited_at]
    collect_health_stats(sync, errors: sync_errors.presence, rate_limited: rate_limited_at.present?, rate_limited_at: rate_limited_at)
  rescue Provider::Moomoo::MoomooError => e
    category = e.reauth_required? || e.error_type == :not_connected ? "auth_error" : "sync_error"
    collect_health_stats(sync, errors: [ { message: e.message, category: category } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    def update_status(sync, key, **options)
      sync.update!(status_text: I18n.t("moomoo_items.sync.status.#{key}", **options)) if sync.respond_to?(:status_text)
    end

    # What the importer could not fetch; it kept the stored copy of each.
    def import_errors(import_result)
      Array(import_result[:failures]).map do |failure|
        {
          name: [ failure[:account], I18n.t("moomoo_items.sync.failures.#{failure[:what]}", market: failure[:market]) ].compact.join(" · "),
          message: failure[:message],
          category: failure[:what].in?(ACCOUNT_FAILURES) ? "sync_error" : "partial_fetch"
        }
      end
    end

    # A row of a split account whose own account isn't set up is not
    # imported anywhere, though the account's other rows are.
    def unlinked_currency_notices
      moomoo_item.linkable_moomoo_accounts
        .includes(:account_provider, primary_moomoo_account: :account_provider, currency_accounts: :account_provider)
        .select { |row| row.current_account.nil? && row.sibling_currency_accounts.any? { |sibling| sibling.current_account.present? } }
        .map { |row| { message: I18n.t("moomoo_items.sync.notices.currency_not_linked", name: row.name), severity: "info" } }
    end

    def account_errors(process_results, schedule_results)
      [ *process_results, *schedule_results ].filter_map do |result|
        { message: result[:error], category: "sync_error" } unless result[:success]
      end
    end

    # An account the sync couldn't refresh was left as it is.
    def count_holdings(moomoo_accounts)
      moomoo_accounts.reject(&:snapshot_stale?).sum { |moomoo_account| moomoo_account.importable_positions.map { |position| position["code"] }.uniq.size }
    end
end
