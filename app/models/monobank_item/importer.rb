# Imports Monobank cards, jars and statement history for a single MonobankItem.
#
# Monobank's personal API is heavily rate limited (one request per minute, per endpoint)
# and caps a statement request at 31 days, which drives the whole design here:
#
# * client-info is fetched once per sync and reused for every account snapshot.
# * Each linked account gets a *forward* statement window (new activity since the last
#   sync, always re-covering the last few days so unsettled holds stay visible) and,
#   when budget remains, one *backward* window that walks older history towards the
#   configured start date across successive syncs.
# * The number of statement requests per sync is capped so a family with many accounts
#   cannot turn one sync into an hour of throttled sleeping.
class MonobankItem::Importer
  attr_reader :monobank_item, :monobank_provider

  # Build an importer for the given +monobank_item+ using the supplied provider client.
  def initialize(monobank_item, monobank_provider:)
    @monobank_item = monobank_item
    @monobank_provider = monobank_provider
    @statement_requests_remaining = self.class.max_statement_requests_per_sync
  end

  # Maximum statement requests one sync may spend, across all of the item's accounts.
  def self.max_statement_requests_per_sync
    Rails.configuration.x.monobank.max_statement_requests_per_sync
  end

  # Run the full import (accounts then statements) and return a result hash of success
  # flag and per-entity counts. On a failed client-info fetch, returns a +failed_result+
  # with the same shape and zeroed counts; on a throttled one, a +throttled_result+ that
  # defers the work to the next sync.
  def import
    Rails.logger.info "MonobankItem::Importer - Starting import for item #{monobank_item.id}"

    client_info = fetch_client_info
    unless client_info
      return throttled_result if @client_info_throttled
      return failed_result("Failed to fetch client info")
    end

    monobank_item.upsert_monobank_snapshot!(client_info)

    accounts_data = monobank_provider.get_accounts(client_info: client_info)
    account_stats = import_accounts(accounts_data)
    transaction_stats = import_transactions

    Rails.logger.info(
      "MonobankItem::Importer - Completed import for item #{monobank_item.id}: " \
      "#{account_stats[:updated]} accounts updated, #{account_stats[:created]} new accounts discovered, " \
      "#{transaction_stats[:imported]} transactions, #{transaction_stats[:skipped]} accounts skipped"
    )

    {
      success: account_stats[:failed].zero? && transaction_stats[:failed].zero?,
      accounts_updated: account_stats[:updated],
      accounts_created: account_stats[:created],
      accounts_failed: account_stats[:failed],
      transactions_imported: transaction_stats[:imported],
      transactions_failed: transaction_stats[:failed],
      accounts_skipped: transaction_stats[:skipped]
    }
  end

  private

    attr_reader :statement_requests_remaining

    # Fetch the client profile (with cards and jars), returning nil on any provider or
    # parse error, which is logged and captured for support. A throttle is flagged
    # separately so +import+ can defer the sync instead of failing it.
    def fetch_client_info
      client_info = monobank_provider.get_client_info

      if Rails.configuration.x.monobank.debug_raw && Rails.env.local?
        Rails.logger.debug "Monobank raw client-info response: #{client_info.to_json}"
      end

      client_info
    rescue Provider::Monobank::RateLimitError => e
      Rails.logger.warn "MonobankItem::Importer - Monobank rate limit hit while fetching client info"
      capture_sync_error("Rate limited while fetching client info", e, level: "warn")
      @client_info_throttled = true
      nil
    rescue Provider::Monobank::Error => e
      mark_requires_update! if e.failure_code.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "MonobankItem::Importer - Monobank API error: #{e.failure_code}"
      capture_sync_error("Failed to fetch client info", e, error_type: e.failure_code)
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "MonobankItem::Importer - Failed to parse Monobank API response: #{e.class}"
      capture_sync_error("Failed to parse Monobank client info response", e)
      nil
    rescue => e
      Rails.logger.error "MonobankItem::Importer - Unexpected error fetching client info: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      capture_sync_error("Unexpected error fetching client info", e)
      nil
    end

    # Upsert snapshots for linked accounts and record newly discovered ones, returning a
    # stats hash of +updated+, +created+ and +failed+ counts.
    def import_accounts(accounts_data)
      stats = { updated: 0, created: 0, failed: 0 }
      accounts = Array(accounts_data)
      linked_account_ids = monobank_item.monobank_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
      all_existing_ids = monobank_item.monobank_accounts.pluck(:account_id).map(&:to_s)

      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?

        if linked_account_ids.include?(account_id.to_s)
          import_account(account)
          stats[:updated] += 1
        elsif !all_existing_ids.include?(account_id.to_s)
          monobank_account = monobank_item.monobank_accounts.build(account_id: account_id.to_s)
          monobank_account.upsert_monobank_snapshot!(account)
          stats[:created] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "MonobankItem::Importer - Failed to import account #{account_id}: #{e.class}"
        capture_sync_error(
          "Failed to import Monobank account",
          e,
          monobank_account: monobank_item.monobank_accounts.find_by(account_id: account_id.to_s),
          extra_metadata: { provider_account_id: account_id.to_s }
        )
      end

      stats
    end

    # Upsert the snapshot for a single already-linked Monobank account.
    def import_account(account_data)
      account = account_data.with_indifferent_access
      monobank_account = monobank_item.monobank_accounts.find_by(account_id: account[:id].to_s)
      return unless monobank_account

      monobank_account.upsert_monobank_snapshot!(account)
    end

    # Fetch and store statements for every visible linked account, returning a stats
    # hash of +imported+, +failed+ and +skipped+ counts. An account skipped because the
    # request budget ran out (or because Monobank throttled us) is not a failure: the
    # next sync picks it up.
    def import_transactions
      stats = { imported: 0, failed: 0, skipped: 0 }

      # Least-recently-covered accounts first, so a budget too small for every account
      # still rotates fairly instead of starving the same ones every sync.
      accounts = monobank_item.monobank_accounts
                              .joins(:account).merge(Account.visible)
                              .order(Arel.sql("statement_synced_through ASC NULLS FIRST"))

      accounts.each do |monobank_account|
        if statement_requests_remaining <= 0
          stats[:skipped] += 1
          Rails.logger.info(
            "MonobankItem::Importer - Statement request budget exhausted, deferring account " \
            "#{monobank_account.id} to the next sync"
          )
          next
        end

        result = fetch_and_store_transactions(monobank_account)
        if result[:success]
          stats[:imported] += result[:transactions_count]
        elsif result[:skipped]
          stats[:skipped] += 1
        else
          stats[:failed] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "MonobankItem::Importer - Failed to fetch/store statement for Monobank account #{monobank_account.id}: #{e.class}"
        # fetch_window captures its own provider errors; what lands here instead is a
        # persistence failure (an invalid snapshot, a cursor that will not save), which
        # otherwise showed up only as an incremented failure count.
        capture_sync_error(
          "Failed to fetch or store a Monobank statement",
          e,
          monobank_account: monobank_account
        )
      end

      stats
    end

    # Fetch the forward window (and, when budget allows, one backward history window)
    # for +monobank_account+ and persist the results.
    def fetch_and_store_transactions(monobank_account)
      fetched = []

      forward = fetch_forward_window(monobank_account)
      return forward if forward[:error] || forward[:skipped]

      fetched.concat(forward[:transactions])

      backward = fetch_history_window(monobank_account)
      fetched.concat(backward[:transactions]) if backward[:transactions]

      # Persist before propagating a backward failure: the forward window is already in
      # hand, and dropping it would leave the account further behind next sync for no
      # gain. The forward cursor is only advanced by what was actually covered.
      store_transactions(monobank_account, fresh_transactions: fetched, pending_covered_from: forward[:covered_from])
      monobank_account.save! if monobank_account.changed?

      return backward.merge(transactions_count: fetched.count) if backward[:error]

      { success: true, transactions_count: fetched.count }
    end

    # New activity since the last covered timestamp. The window always re-covers the
    # last few days (pending_lookback_days), and any older hold still on file, so a hold
    # that is still unsettled stays in the payload — pending entries are pruned when
    # they drop out of it.
    def fetch_forward_window(monobank_account)
      now = Time.current
      lookback_start = now - Rails.configuration.x.monobank.pending_lookback_days.days

      requested_from = if monobank_account.statement_synced_through.present?
        [ monobank_account.statement_synced_through, lookback_start, oldest_stored_hold_time(monobank_account) ].compact.min
      else
        initial_history_start(monobank_account)
      end
      from = [ requested_from, now - Provider::Monobank::MAX_STATEMENT_WINDOW ].max

      result = fetch_window(monobank_account, from: from, to: now, direction: :forward)
      return result unless result[:success]

      transactions = result[:transactions]
      previously_covered_through = monobank_account.statement_synced_through
      truncated = truncated?(transactions)

      # What the response actually accounts for. A response at the item cap is missing
      # the oldest part of the window, and Monobank returns a statement newest-first, so
      # only [oldest_received, now] arrived.
      covered_from = if truncated
        capture_truncated_window(monobank_account, from: from, to: now)
        oldest_transaction_time(transactions) || from
      else
        from
      end

      monobank_account.statement_synced_through = now
      monobank_account.history_synced_from = if truncated
        # Coverage is still contiguous with what was already stored as long as the
        # previous coverage reached the oldest record received; if it did not, the gap
        # below it has to be re-walked, which is what moving the history cursor up to
        # that record does.
        if previously_covered_through.present? && previously_covered_through >= covered_from
          monobank_account.history_synced_from
        else
          covered_from
        end
      elsif previously_covered_through.present? && from > previously_covered_through
        # The requested window was wider than Monobank's 31-day cap, so the interval
        # between the old cursor and +from+ was never asked for. Hand it to the backward
        # walk instead of letting both cursors report it as covered; store_transactions
        # dedupes by canonical id, so re-fetching what is already stored is harmless.
        from
      else
        [ monobank_account.history_synced_from, from ].compact.min
      end

      result.merge(covered_from: covered_from)
    end

    # One step of the backward history walk: fetch the 31 days below the oldest date
    # covered so far, until the configured start date is reached. Returns an empty
    # result when there is nothing left to backfill or no request budget for it.
    def fetch_history_window(monobank_account)
      return { transactions: [] } if statement_requests_remaining <= 0

      target_start = initial_history_start(monobank_account)
      covered_from = monobank_account.history_synced_from
      return { transactions: [] } if covered_from.blank? || covered_from <= target_start

      to = covered_from
      from = [ target_start, to - Provider::Monobank::MAX_STATEMENT_WINDOW ].max
      return { transactions: [] } if from >= to

      result = fetch_window(monobank_account, from: from, to: to, direction: :backward)
      # A throttled backward walk is a soft skip, not a failure: the forward window
      # still landed and the backfill simply resumes next sync, exactly as it does when
      # the request budget runs out. A hard failure (auth, parse, provider error) has to
      # reach the caller instead, or the sync reports success while silently never
      # having fetched the configured history.
      return { transactions: [] } if result[:skipped]
      return result unless result[:success]

      transactions = result[:transactions]
      monobank_account.history_synced_from = if truncated?(transactions)
        oldest_transaction_time(transactions) || from
      else
        from
      end

      result
    end

    # Perform a single statement request, spending one unit of the request budget.
    # Provider errors are classified: a throttle is a soft skip, an auth failure marks
    # the connection as needing attention, anything else is a hard failure.
    def fetch_window(monobank_account, from:, to:, direction:)
      @statement_requests_remaining -= 1

      Rails.logger.info(
        "MonobankItem::Importer - Fetching #{direction} statement for Monobank account " \
        "#{monobank_account.id} from #{from.iso8601} to #{to.iso8601}"
      )

      transactions = monobank_provider.get_statement(
        account_id: monobank_account.account_id,
        from: from,
        to: to
      )

      if Rails.configuration.x.monobank.debug_raw && Rails.env.local?
        Rails.logger.debug "Monobank raw statement response: #{transactions.to_json}"
      end

      { success: true, transactions: Array(transactions) }
    rescue Provider::Monobank::RateLimitError => e
      Rails.logger.warn "MonobankItem::Importer - Monobank rate limit hit for account #{monobank_account.id}"
      capture_sync_error("Rate limited while fetching statement", e, monobank_account: monobank_account, level: "warn")
      { success: false, skipped: true, transactions_count: 0 }
    rescue Provider::Monobank::Error => e
      mark_requires_update! if e.failure_code.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "MonobankItem::Importer - Monobank API error for account #{monobank_account.id}: #{e.failure_code}"
      capture_sync_error("Failed to fetch statement", e, monobank_account: monobank_account, error_type: e.failure_code)
      { success: false, error: I18n.t("monobank_item.errors.transactions_failed"), transactions_count: 0 }
    rescue JSON::ParserError => e
      Rails.logger.error "MonobankItem::Importer - Failed to parse statement response for account #{monobank_account.id}: #{e.class}"
      capture_sync_error("Failed to parse Monobank statement response", e, monobank_account: monobank_account)
      { success: false, error: "Failed to parse response", transactions_count: 0 }
    rescue => e
      Rails.logger.error "MonobankItem::Importer - Unexpected error fetching statement for account #{monobank_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      capture_sync_error("Unexpected error fetching statement", e, monobank_account: monobank_account)
      { success: false, error: I18n.t("monobank_item.errors.transactions_failed"), transactions_count: 0 }
    end

    # Monobank returns settled and held transactions from the same endpoint. Settled
    # history accumulates; a held transaction is dropped once the statement that covered
    # it stops reporting it, so a hold that settled (Monobank may issue the settled
    # record under a different id) or was cancelled leaves storage and the transactions
    # processor retires the pending entry it created. A hold below what the response
    # actually covered is kept: see #stale_pending?.
    # Note on growth: like the other providers here, settled history accumulates in the
    # account's raw_transactions_payload and is re-processed in full on every sync. That
    # is fine for the default 31-day window; a connection configured to reach back years
    # will make each sync progressively heavier.
    def store_transactions(monobank_account, fresh_transactions:, pending_covered_from: nil)
      fresh_transactions = fresh_transactions.reject { |tx| MonobankEntry::Processor.pending?(tx) } unless include_pending?

      existing = monobank_account.raw_transactions_payload.to_a
      retained = existing.reject { |tx| stale_pending?(tx, covered_from: pending_covered_from) }

      by_id = {}
      retained.each do |tx|
        key = transaction_key(tx)
        by_id[key] = tx if key.present?
      end
      fresh_transactions.each do |tx|
        next unless tx.is_a?(Hash)

        key = transaction_key(tx)
        by_id[key] = tx if key.present?
      end

      final_transactions = by_id.values

      if final_transactions != existing
        Rails.logger.info(
          "MonobankItem::Importer - Storing #{final_transactions.count} transactions " \
          "(#{existing.count} existing) for account #{monobank_account.account_id}"
        )
        monobank_account.upsert_monobank_transactions_snapshot!(final_transactions)
      else
        Rails.logger.info "MonobankItem::Importer - No transaction changes for account #{monobank_account.account_id}"
      end
    end

    # Dedup key for a stored transaction: the canonical external id, so an id-less
    # record still collapses onto its content hash instead of duplicating.
    def transaction_key(transaction)
      return nil unless transaction.is_a?(Hash)

      MonobankEntry::Processor.canonical_external_id(transaction)
    end

    # Whether held (pending) transactions are imported at all.
    def include_pending?
      Rails.configuration.x.monobank.include_pending
    end

    # A response that hit Monobank's per-response item cap is assumed to cover only part
    # of the requested window.
    def truncated?(transactions)
      transactions.size >= Provider::Monobank::MAX_STATEMENT_ITEMS
    end

    # Whether a stored hold the latest statement no longer reports has really gone away.
    # Only a hold the response actually accounted for can be stale (RedbarkItem::Importer
    # #merge_transactions pairs the same two checks): below that point Monobank was never
    # asked, and dropping the hold would delete a pre-authorization that is still
    # blocking funds — a hotel or car hire hold outlives the pending lookback easily.
    def stale_pending?(transaction, covered_from:)
      return false unless transaction.is_a?(Hash)
      return false unless MonobankEntry::Processor.pending?(transaction)
      return true if covered_from.blank?

      time = transaction_time(transaction)
      # Undated, or covered by the statement just fetched and absent from it: the hold
      # settled or was cancelled.
      return true if time.blank? || time >= covered_from

      # Older than one statement window, so Monobank cannot be asked about it again.
      # Keeping it would leave a pending entry that can never clear.
      time < Time.current - Provider::Monobank::MAX_STATEMENT_WINDOW
    end

    # Timestamp of the oldest hold still on file. A hold can stay unsettled for longer
    # than the lookback (hotels, car hire, fuel), so the forward window reaches back to
    # it and keeps asking Monobank whether it has settled or been cancelled.
    def oldest_stored_hold_time(monobank_account)
      return nil unless include_pending?

      holds = monobank_account.raw_transactions_payload.to_a.select do |transaction|
        transaction.is_a?(Hash) && MonobankEntry::Processor.pending?(transaction)
      end

      transaction_times(holds).min
    end

    # Timestamp of the oldest record in a response, used to work out how much of a
    # truncated window actually arrived.
    def oldest_transaction_time(transactions)
      transaction_times(transactions).min
    end

    def transaction_times(transactions)
      transactions.filter_map { |transaction| transaction_time(transaction) }
    end

    # When Monobank says a single record happened, or nil when it omitted the field.
    def transaction_time(transaction)
      return nil unless transaction.is_a?(Hash)

      value = transaction.with_indifferent_access[:time]
      return nil if value.blank?

      Time.at(value.to_i)
    end

    # The timestamp history should reach back to: an explicit per-account or
    # per-connection start date, else the configured default window. A timestamp rather
    # than a date, because the cursors record exactly what a window covered.
    def initial_history_start(monobank_account)
      start_date = monobank_account.sync_start_date.presence || monobank_item.sync_start_date.presence
      # in_time_zone, not to_time: to_time reads the date in the server process's own
      # zone, which would move the window whenever TZ differs between web and worker.
      return start_date.in_time_zone if start_date

      Rails.configuration.x.monobank.initial_history_days.days.ago
    end

    # Record a note (not an error) when a statement window came back full, since it
    # explains why history is arriving in stages.
    def capture_truncated_window(monobank_account, from:, to:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "info",
        message: "Monobank statement window truncated at the response item cap",
        source: self.class.name,
        provider_key: "monobank",
        family: monobank_item.family,
        account_provider: monobank_account.account_provider,
        metadata: {
          monobank_item_id: monobank_item.id,
          monobank_account_id: monobank_account.id,
          window_from: from.iso8601,
          window_to: to.iso8601,
          item_cap: Provider::Monobank::MAX_STATEMENT_ITEMS
        }
      )
    end

    # Record a provider sync problem as a DebugLogEntry with structured metadata for
    # support, attaching family and account provider when available.
    def capture_sync_error(message, error, monobank_account: nil, error_type: nil, level: "error", extra_metadata: {})
      metadata = { monobank_item_id: monobank_item.id, error_class: error.class.name, error_message: error.message }
      metadata[:monobank_account_id] = monobank_account.id if monobank_account
      metadata[:error_type] = error_type if error_type
      metadata.merge!(extra_metadata)

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "monobank",
        family: monobank_item.family,
        account_provider: monobank_account&.account_provider,
        metadata: metadata
      )
    end

    # Flag the item as requiring re-authorization, swallowing update errors. A failure
    # here means the connection keeps showing as healthy after its token was rejected,
    # so it is recorded where support can find it rather than only in the app log.
    def mark_requires_update!
      monobank_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "MonobankItem::Importer - Failed to update item status: #{e.class}"
      capture_sync_error("Failed to flag connection as requiring re-authorization", e)
    end

    # Build a skip result mirroring +import+'s shape. Monobank throttles client-info to
    # one request per minute and the timer is not shared across processes, so a manual
    # sync landing in the same minute as a scheduled one (or as a setup screen) collides
    # legitimately. Like a throttled statement that is a skip, not a broken connection:
    # nothing was fetched, the connection stays healthy, the next sync picks it up.
    def throttled_result
      {
        success: true,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0,
        accounts_skipped: monobank_item.monobank_accounts.joins(:account).merge(Account.visible).count
      }
    end

    # Build a failure result mirroring +import+'s shape with zeroed counts.
    def failed_result(error)
      {
        success: false,
        error: error,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0,
        accounts_skipped: 0
      }
    end
end
