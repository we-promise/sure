# frozen_string_literal: true

# Fetches one statement per sync and persists it raw.
#
# A Fio token may be used once per 30 seconds, so the window is chosen to need a single
# request: from the day the last sync covered (minus an overlap) to today. The statement
# header doubles as account discovery, so the first sync of a new connection creates the
# `fio_accounts` row from the same response that brings the movements.
#
# Turning stored movements into entries is FioAccount::Processor's job.
class FioItem::Importer
  attr_reader :fio_item, :fio_provider

  def initialize(fio_item, fio_provider:)
    @fio_item = fio_item
    @fio_provider = fio_provider
  end

  # Days of history a new connection reaches back on its first sync.
  def self.initial_history_days
    Rails.configuration.x.fio.initial_history_days
  end

  # Days before the last covered day that each subsequent sync re-reads.
  def self.sync_lookback_days
    Rails.configuration.x.fio.sync_lookback_days
  end

  # Returns a result hash with a `success` flag and per-entity counts. A throttled
  # request (HTTP 409) defers to the next sync and keeps the connection healthy.
  def import
    Rails.logger.info "FioItem::Importer - Starting import for item #{fio_item.id}"

    window = statement_window
    statement = fetch_statement(from: window.first, to: window.last)
    return @deferred_result if statement.nil?

    info = statement[:info]
    transactions = extract_transactions(statement)

    if info.blank? && fio_account.nil?
      # Nothing to describe the account with and nothing stored from a previous sync:
      # a brand-new connection whose first window happens to be empty. The account is
      # discovered by the next sync rather than invented here.
      Rails.logger.info "FioItem::Importer - Statement carried no account header for item #{fio_item.id}"
      return empty_result
    end

    return @deferred_result if reject_foreign_account!(info)

    fio_item.upsert_fio_snapshot!(info) if info.present?

    # A quiet range answers with an empty body and no header, so an established
    # connection keeps the account it already discovered.
    account = info.present? ? upsert_account!(info) : fio_account
    created = info.present? && account.previously_new_record?

    store_transactions(account, fresh_transactions: transactions)
    account.update!(
      transactions_synced_through: window.last,
      history_synced_from: [ @served_from, account.history_synced_from ].compact.min
    )

    dump_raw(window: window, transactions: transactions)

    Rails.logger.info(
      "FioItem::Importer - Completed import for item #{fio_item.id}: " \
      "#{transactions.size} movements in #{window.first}..#{window.last}"
    )

    {
      success: true,
      accounts_updated: created ? 0 : 1,
      accounts_created: created ? 1 : 0,
      accounts_failed: 0,
      transactions_imported: transactions.size,
      transactions_failed: 0
    }
  end

  private

    def fio_account
      @fio_account ||= fio_item.fio_accounts.first
    end

    # The day the connection reaches back to: the user's start date, or the configured
    # default when they have not chosen one.
    #
    # Once Fio has refused that range for want of a full-history unlock, the target stays
    # inside the window it serves unauthorized. A sync has exactly one request to spend,
    # and spending it on a period known to be refused would import nothing at all — the
    # user unlocks and syncs deliberately, which clears the flag and reaches for the
    # whole range again.
    def target_start_date
      requested = fio_account&.sync_start_date ||
        fio_item.sync_start_date ||
        (Date.current - self.class.initial_history_days.days)

      return requested if fio_item.history_unlock_required_at.blank?

      [ requested, Date.current - (Provider::Fio::UNAUTHORIZED_HISTORY_DAYS - 1).days ].max
    end

    # The window to request, ending today.
    #
    # Fio books a movement under its banking date, which can be a day or two behind the
    # day it becomes visible, so a sync re-reads `sync_lookback_days` before the last
    # covered day instead of resuming exactly where it stopped. Re-reading costs nothing:
    # movements carry stable ids and collapse onto the entries they already produced.
    #
    # Until the history reaches back to the start date the whole range is requested
    # instead, so a backfill that Fio refused for want of an unlock is retried on the
    # next sync rather than being silently abandoned.
    def statement_window
      today = Date.current
      target = target_start_date
      covered_through = fio_account&.transactions_synced_through
      history_from = fio_account&.history_synced_from

      # Both cursors are written by the same update, so a missing history marker means
      # this connection has never fetched anything rather than an unfinished backfill.
      from =
        if covered_through.blank? || (history_from.present? && history_from > target)
          target
        else
          [ covered_through - self.class.sync_lookback_days.days, target ].max
        end

      from = today if from > today

      from..today
    end

    # Performs the request, classifying the failures Fio documents. Returns nil when the
    # sync could not fetch anything, having set @deferred_result. `@served_from` records
    # the start of the window Fio answered, which is what the history cursor is allowed
    # to claim as covered.
    def fetch_statement(from:, to:)
      statement = fio_provider.get_statement(from: from, to: to)
      @served_from = from
      statement
    rescue Provider::Fio::RateLimitError => e
      # One request per 30 seconds per token. A manual sync landing right after a
      # scheduled one collides legitimately: nothing was fetched, the connection is
      # healthy, the next sync picks it up.
      capture_sync_error("Fio statement request was throttled", e, level: "warn", error_type: e.failure_code)
      @deferred_result = empty_result
      nil
    rescue Provider::Fio::HistoryLockedError => e
      # The range reaches past the 90 days Fio serves without a temporary full-history
      # unlock. Retrying clamped right here would be a second use of the same token
      # inside its 30-second interval, which Fio answers with 409 — so the clamp is
      # persisted and the next sync spends its request on a window that will be served.
      fio_item.update!(history_unlock_required_at: Time.current)
      capture_sync_error(
        "Fio refused the statement period pending a full-history unlock",
        e,
        error_type: e.failure_code,
        extra_metadata: { requested_from: from.iso8601 }
      )
      @deferred_result = failed_result(I18n.t("fio_item.errors.history_locked"))
      nil
    rescue Provider::Fio::TooManyItemsError => e
      capture_sync_error("Fio statement exceeded the per-request movement limit", e, error_type: e.failure_code)
      @deferred_result = failed_result(I18n.t("fio_item.errors.statement_too_large"))
      nil
    rescue Provider::Fio::Error => e
      mark_requires_update! if e.failure_code == :unauthorized
      capture_sync_error("Failed to fetch Fio statement", e, error_type: e.failure_code)
      @deferred_result = failed_result(I18n.t("fio_item.errors.statement_fetch_failed"))
      nil
    end

    def extract_transactions(statement)
      list = statement.dig(:transactionList, :transaction)
      Array(list).select { |transaction| transaction.is_a?(Hash) }
    end

    # A connection stands for one token, and a token for one account, so a statement
    # naming a different account than the one already stored means the token was
    # replaced with one for another account. Reusing the row would hand the linked Sure
    # account someone else's balance and movements, so the sync refuses instead; the
    # user gets a second connection for the second account.
    def reject_foreign_account!(info)
      return false if info.blank?

      stored = fio_account&.fio_account_id
      incoming = info[:accountId].presence&.to_s
      return false if stored.blank? || incoming.blank? || stored == incoming

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Fio token resolves to a different account than this connection",
        source: self.class.name,
        provider_key: "fio",
        family: fio_item.family,
        account_provider: fio_account&.account_provider,
        metadata: { fio_item_id: fio_item.id, fio_account_id: fio_account&.id }
      )

      @deferred_result = failed_result(I18n.t("fio_item.errors.account_mismatch"))
      true
    end

    # Creates the account row on first sight, updates the header afterwards. Discovery
    # never creates a Sure account: linking is the user's decision, made in setup.
    def upsert_account!(info)
      account_number = info[:accountId].presence&.to_s
      account = fio_item.fio_accounts.find_by(fio_account_id: account_number) ||
        fio_account ||
        fio_item.fio_accounts.new(currency: info[:currency], name: "")

      account.upsert_fio_snapshot!(info)
      @fio_account = account
    end

    # Merges the fetched movements into the stored payload, keyed by movement id, and
    # saves only when something changed.
    def store_transactions(account, fresh_transactions:)
      existing = account.raw_transactions_payload.to_a

      by_id = {}
      (existing + fresh_transactions).each do |transaction|
        next unless transaction.is_a?(Hash)

        key = FioEntry::Processor.canonical_external_id(transaction)
        by_id[key] = transaction if key.present?
      end

      final_transactions = by_id.values
      return if final_transactions == existing

      Rails.logger.info(
        "FioItem::Importer - Storing #{final_transactions.count} movements " \
        "(#{existing.count} existing) for account #{account.id}"
      )
      account.upsert_fio_transactions_snapshot!(final_transactions)
    end

    # Local-only raw dump. The payload carries counterparty names, account numbers and
    # payment messages, so it never runs outside development.
    def dump_raw(window:, transactions:)
      return unless Rails.configuration.x.fio.debug_raw && Rails.env.local?

      Rails.logger.info(
        "FioItem::Importer - Raw Fio statement #{window.first}..#{window.last}: #{transactions.inspect}"
      )
    end

    def capture_sync_error(message, error, error_type: nil, level: "error", extra_metadata: {})
      metadata = { fio_item_id: fio_item.id, error_class: error.class.name, error_message: error.message }
      metadata[:fio_account_id] = fio_account.id if fio_account
      metadata[:error_type] = error_type if error_type
      metadata.merge!(extra_metadata)

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "fio",
        family: fio_item.family,
        account_provider: fio_account&.account_provider,
        metadata: metadata
      )
    end

    # Flag the item as needing a new token, swallowing update errors. A failure here
    # means the connection keeps showing as healthy after its token was rejected, so it
    # is recorded where support can find it rather than only in the app log.
    def mark_requires_update!
      fio_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "FioItem::Importer - Failed to update item status: #{e.class}"
      capture_sync_error("Failed to flag connection as requiring a new token", e)
    end

    # Nothing fetched, nothing broken: the next sync tries again.
    def empty_result
      {
        success: true,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end

    def failed_result(error)
      {
        success: false,
        error: error,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 1,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end
end
