class StashawayItem::Syncer
  include SyncStats::Collector

  attr_reader :stashaway_item

  def initialize(stashaway_item)
    @stashaway_item = stashaway_item
  end

  def perform_sync(sync)
    sign_in_again(sync) unless stashaway_item.ready_for_sync?

    import(sync)

    collect_setup_stats(sync, provider_accounts: stashaway_item.stashaway_accounts.to_a)
    unlinked = stashaway_item.unlinked_accounts_count
    stashaway_item.update!(pending_account_setup: unlinked.positive?)
    sync.update!(status_text: I18n.t("stashaway_items.sync.status.accounts_need_setup", count: unlinked)) if unlinked.positive? && sync.respond_to?(:status_text)

    errors = []
    linked_accounts = stashaway_item.linked_stashaway_accounts.joins(:account).merge(Account.visible)
    if linked_accounts.any?
      sync.update!(status_text: I18n.t("stashaway_items.sync.status.processing")) if sync.respond_to?(:status_text)
      process_results = stashaway_item.process_accounts
      schedule_results = stashaway_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      errors = [ *process_results, *schedule_results ].filter_map { |result| { message: result[:error], category: "sync_error" } unless result[:success] }

      account_ids = linked_accounts.includes(:account).filter_map { |stashaway_account| stashaway_account.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: StashawayAccount::SOURCE)
      collect_plan_warnings(sync, process_results)
    end

    collect_health_stats(sync, errors: errors.presence)
  rescue Provider::Stashaway::AuthenticationError => e
    stashaway_item.require_reauthentication!
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    # A token StashAway stopped accepting is dropped and, when the item has
    # a saved password, replaced by a new sign-in; the import is then tried
    # once more.
    def import(sync)
      sync.update!(status_text: I18n.t("stashaway_items.sync.status.importing")) if sync.respond_to?(:status_text)
      stashaway_item.import_latest_data
    rescue Provider::Stashaway::AuthenticationError
      stashaway_item.require_reauthentication!
      raise unless stashaway_item.password_saved?

      sign_in_again(sync)
      sync.update!(status_text: I18n.t("stashaway_items.sync.status.importing")) if sync.respond_to?(:status_text)
      stashaway_item.import_latest_data
    end

    # Signs in with the saved password, or says why the connection cannot
    # sync: it has no saved password, or StashAway wants an SMS code first.
    # A code that was asked for is waited for even past its window, as
    # another sign-in by itself would send another SMS on every sync.
    def sign_in_again(sync)
      raise Provider::Stashaway::AuthenticationError, I18n.t("stashaway_items.sync.errors.sign_in_required") unless stashaway_item.password_saved?
      raise Provider::Stashaway::AuthenticationError, I18n.t("stashaway_items.sync.errors.code_required") if stashaway_item.pending_login_token.present?

      sync.update!(status_text: I18n.t("stashaway_items.sync.status.signing_in")) if sync.respond_to?(:status_text)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "StashawayItem #{stashaway_item.id} - Signing in again with the saved password",
        source: "stashaway",
        family: stashaway_item.family,
        provider_key: "stashaway"
      )
      outcome = stashaway_item.start_login!(password: stashaway_item.password, remember: true)
      raise Provider::Stashaway::AuthenticationError, I18n.t("stashaway_items.sync.errors.code_required") if outcome == :code_sent
    rescue Provider::Stashaway::InvalidCredentials => e
      # The password has changed, so it is of no further use.
      stashaway_item.forget_password!
      raise Provider::Stashaway::AuthenticationError, I18n.t("stashaway_items.sync.errors.password_refused", detail: e.message)
    rescue StashawayItem::Authentication::AlreadyConnected
      raise Provider::Stashaway::AuthenticationError, I18n.t("stashaway_items.login.already_connected")
    rescue StashawayItem::Authentication::AccountMismatch
      raise Provider::Stashaway::AuthenticationError, I18n.t("stashaway_items.login.account_mismatch")
    end

    # Rows the plan could not place, such as a USD dividend with no rate,
    # are left to the month's returns adjustment; the sync lists them.
    def collect_plan_warnings(sync, process_results)
      warnings = Array(process_results).flat_map do |result|
        processed = result[:result]
        processed.respond_to?(:warnings) ? processed.warnings : []
      end
      return if warnings.empty?

      collect_data_quality_stats(sync, warnings: warnings.size, details: warnings.map { |message| { message: message, severity: "warning" } })
    end
end
