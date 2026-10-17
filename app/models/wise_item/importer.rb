# frozen_string_literal: true

class WiseItem::Importer
  DEFAULT_HISTORY_DAYS = 365
  # Wise has existed since 2011, so this safely predates any account creation.
  FULL_HISTORY_START_DATE = Date.new(2000, 1, 1)
  PAGE_SIZE = 100

  # An incremental fetch starts before the end of the last successful one
  # (its coverage `through`) so late arrivals and status changes are read
  # again: transfers 14 days before it and never later than 60 days ago (a
  # sent payout can still bounce), activities 30 days before it or a day
  # before the oldest stored activity that can still change, if that is
  # within 180 days (activities cannot be read by id).
  TRANSFER_OVERLAP = 14.days
  TRANSFER_RECHECK_PERIOD = 60.days
  ACTIVITY_OVERLAP = 30.days
  UNFINISHED_ACTIVITY_LOOKBACK = 180.days
  FINAL_ACTIVITY_STATUSES = %w[COMPLETED CANCELLED].freeze

  # A transfer in one of these statuses no longer changes. Stored transfers
  # in any other status but outgoing_payment_sent (which the 60-day window
  # re-lists) are read again by id each sync, newest first.
  FINAL_TRANSFER_STATUSES = %w[cancelled funds_refunded charged_back].freeze
  MAX_TRANSFER_REREADS = 50
  # A stored transfer Wise no longer finds by id is read again on this many
  # syncs ("wise_missing_count" on its stored copy), then left as stored.
  MISSING_TRANSFER_REREADS = 3

  # Wise answered with a page this fetch had already read.
  PaginationError = Class.new(StandardError)

  attr_reader :wise_item, :wise_provider, :sync_start_date

  def initialize(wise_item, wise_provider:, sync_start_date: nil)
    @wise_item = wise_item
    @wise_provider = wise_provider
    @sync_start_date = sync_start_date
    @fetch_failures = 0
    @fetched_windows = {}
    @statement_retry_accounts = []
    @statements_refused_accounts = []
  end

  # `complete:` is true only when every source this sync needed arrived in
  # full: balances, transfers and their re-reads, activities, and statements
  # of balances that already hold statement rows. Steps that delete or
  # rewrite entries must not run after an incomplete import.
  def import
    Rails.logger.info "WiseItem::Importer - Starting import for item #{wise_item.id} (profile #{wise_item.profile_id})"

    balances = fetch_balances
    return failed_result("Failed to fetch balances") if balances.nil?

    savings_balances = fetch_savings_balances
    all_balances = Array(balances) + Array(savings_balances)

    @multi_currency_account = fetch_multi_currency_account
    borderless_accounts = fetch_borderless_accounts
    account_result = import_balances(
      all_balances,
      borderless_accounts: borderless_accounts,
      account_recipient_id: @multi_currency_account&.dig("recipientId")
    )

    transfers = fetch_transfers if legacy_transfer_import_needed?
    activities = fetch_activities
    statements = fetch_statements
    statement_fallbacks = statement_fetches_failed_completely?
    transfers = fetch_transfers if (statement_fallbacks || statements_missing?) && !@transfers_attempted
    transaction_result = store_transfers_per_account(
      transfers || [],
      activities: activities || [],
      statements: statements,
      statement_failures: @statement_retry_accounts,
      fallback_to_transfers: statement_fallbacks
    )
    # Coverage also claims the fetched rows reached every payload, which
    # they cannot while a balance list failed or a balance was not saved.
    if transaction_result[:transactions_failed].zero? && account_result[:accounts_failed].zero? && !@balance_list_failed
      record_coverage!
    end

    success = account_result[:accounts_failed].zero? && transaction_result[:transactions_failed].zero? && @fetch_failures.zero?
    wise_item.update!(status: :good) if success

    {
      success: success,
      complete: @fetch_failures.zero?,
      fetch_failures: @fetch_failures,
      **account_result,
      **transaction_result
    }
  end

  private

    # nil fails the import. Wise's not_found keeps the "no balances" import
    # going, but like any error it leaves the list incomplete, so nothing may
    # conclude a balance missing from it was closed (#balance_lists_complete?).
    def fetch_balances
      balances = Provider::Wise.with_retries { wise_provider.get_balances(wise_item.profile_id) }
      @standard_balances_complete = true
      balances
    rescue Provider::Wise::WiseError => e
      if e.error_type == :not_found
        Rails.logger.info "WiseItem::Importer - No balances for profile #{wise_item.profile_id}"
        return []
      end
      mark_requires_update_if_credentials_error(e)
      record_fetch_failure("balances", e, level: "error")
      # A rejected token fails the sync instead of completing it with nothing imported
      raise if credentials_error?(e)
      nil
    rescue => e
      record_fetch_failure("balances", e, level: "error")
      nil
    end

    # The import goes on without the jars when their list fails, but it is
    # incomplete and its coverage stays: a jar the list left out stores none
    # of this sync's rows, which a later incremental fetch would not reach.
    def fetch_savings_balances
      balances = Provider::Wise.with_retries { wise_provider.get_savings_balances(wise_item.profile_id) }
      @savings_balances_complete = true
      balances
    rescue Provider::Wise::WiseError => e
      if e.error_type == :not_found
        Rails.logger.info "WiseItem::Importer - No savings (JAR) balances for profile #{wise_item.profile_id}: #{e.message}"
      else
        savings_list_failed(e)
      end
      []
    rescue => e
      savings_list_failed(e)
      []
    end

    def savings_list_failed(error)
      @balance_list_failed = true
      record_fetch_failure("savings_balances", error)
    end

    # Both balance lists arrived in full, so a stored balance missing from
    # them is really gone from Wise.
    def balance_lists_complete?
      @standard_balances_complete == true && @savings_balances_complete == true
    end

    # The account recipient (what transfers into the account target) and the
    # account's creationTime, where a full-history import starts. Kept on the
    # item, so a failed lookup falls back to the last known values.
    def fetch_multi_currency_account
      result = Provider::Wise.with_retries { wise_provider.get_multi_currency_account(wise_item.profile_id) }
      account = result.is_a?(Hash) ? result.slice("id", "recipientId", "creationTime") : {}
      wise_item.merge_sync_metadata!("multi_currency_account" => account) if account.present?
      account.presence || stored_multi_currency_account
    rescue => e
      trace_wise_fetch(operation: "multi_currency_account", status: "failed", level: "warn", error: e)
      stored_multi_currency_account
    end

    def stored_multi_currency_account
      account = wise_item.sync_metadata["multi_currency_account"]
      account if account.is_a?(Hash)
    end

    # Returns a map of { balance_id => { borderless_account_id:, recipient_id: } }.
    # Used in WiseEntry::Processor to distinguish expenses (targetAccount != recipientId)
    # from incomes (targetAccount == recipientId). The recipient is the
    # fallback for the multi-currency account's.
    def fetch_borderless_accounts
      trace_wise_fetch(operation: "borderless_accounts", status: "started", level: "info")
      result = Provider::Wise.with_retries { wise_provider.get_borderless_accounts(wise_item.profile_id) }
      trace_wise_fetch(
        operation: "borderless_accounts",
        status: "completed",
        level: "info",
        received_record_count: Array(result).size
      )
      Array(result).each_with_object({}) do |ba, map|
        borderless_id = ba["id"]
        recipient_id  = ba["recipientId"]
        Array(ba["balances"]).each do |b|
          map[b["id"].to_s] = { borderless_account_id: borderless_id, recipient_id: recipient_id }
        end
      end
    rescue => e
      trace_wise_fetch(operation: "borderless_accounts", status: "failed", level: "warn", error: e)
      {}
    end

    def import_balances(balances, borderless_accounts: {}, account_recipient_id: nil)
      accounts_created = 0
      accounts_updated = 0
      accounts_failed = 0

      existing_ids = wise_item.wise_accounts.pluck(:balance_id).map(&:to_s).to_set

      Array(balances).each do |balance_data|
        data = balance_data.with_indifferent_access
        balance_id = data[:id].to_s
        currency = data.dig(:amount, :currency).to_s

        next if balance_id.blank? || currency.blank?

        account_ids = borderless_accounts[balance_id] || {}

        is_savings = data[:type] == "SAVINGS"
        api_name   = data[:name].presence

        wise_account = wise_item.wise_accounts.find_or_initialize_by(balance_id: balance_id)
        wise_account.currency ||= currency
        wise_account.name ||= api_name || (is_savings ? "Wise JAR #{currency}" : "Wise #{currency}")
        wise_account.upsert_wise_snapshot!(
          data,
          borderless_account_id: account_ids[:borderless_account_id],
          recipient_id: account_recipient_id.presence || account_ids[:recipient_id]
        )

        if existing_ids.include?(balance_id)
          accounts_updated += 1
        else
          accounts_created += 1
          existing_ids << balance_id
        end
      rescue => e
        accounts_failed += 1
        # A new balance that failed to save must not stay among the item's
        # balances unsaved: every later read of them would trip over it.
        wise_item.wise_accounts.reset if wise_account&.new_record?
        Rails.logger.error "WiseItem::Importer - Failed to import balance #{balance_id.presence || 'unknown'}: #{e.message}"
      end

      { accounts_created: accounts_created, accounts_updated: accounts_updated, accounts_failed: accounts_failed }
    end

    # Every activity since the window start, of all types: routing decides
    # what each balance stores. nil when the fetch failed; its pages are
    # dropped and the next sync starts from the same point.
    def fetch_activities
      started_at = Time.current
      since = window_start(:activities)
      activities = []
      cursor = nil
      seen_cursors = Set.new

      loop do
        trace_wise_fetch(operation: "activities", status: "started", level: "info", cursor: cursor, page_size: PAGE_SIZE)
        result = Provider::Wise.with_retries do
          wise_provider.get_activities(wise_item.profile_id, cursor: cursor, size: PAGE_SIZE, since: since)
        end
        batch = Array(result["activities"])
        next_cursor = result["cursor"].presence
        trace_wise_fetch(
          operation: "activities",
          status: "completed",
          level: "info",
          cursor: cursor,
          received_record_count: batch.size,
          next_cursor_present: next_cursor.present?
        )
        activities.concat(batch)
        break if batch.empty? || next_cursor.nil?
        raise PaginationError, "Wise activities pagination cursor did not advance" if seen_cursors.include?(next_cursor)

        seen_cursors << next_cursor
        cursor = next_cursor
      end

      @fetched_windows[:activities] = { start: since, through: started_at }
      activities.uniq { |activity| activity["id"] || activity.to_json }
    rescue => e
      record_fetch_failure("activities", e, cursor: cursor)
      nil
    end

    # Transfers created since the window start, plus the stored ones that can
    # still change, read again by id. nil when the list failed; its pages are
    # dropped and the next sync starts from the same point.
    def fetch_transfers
      @transfers_attempted = true
      started_at = Time.current
      start = window_start(:transfers)
      listed = list_transfers(start)
      return nil if listed.nil?

      @fetched_windows[:transfers] = { start: start, through: started_at }
      listed + Array(reread_transfers(except: listed.map { |transfer| transfer["id"].to_s }))
    end

    # Pages until Wise returns an empty page, without assuming an order.
    # Wise takes an offset only as a multiple of the limit (HTTP 422
    # inconsistent.pagination otherwise), so each page starts PAGE_SIZE rows
    # after the previous one, however many rows that held: a page shorter
    # than the limit need not be the last.
    def list_transfers(start)
      transfers = []
      seen_ids = Set.new
      offset = 0

      loop do
        trace_wise_fetch(operation: "transfers", status: "started", level: "info", offset: offset, page_size: PAGE_SIZE)
        page = Provider::Wise.with_retries do
          wise_provider.get_transfers(wise_item.profile_id, limit: PAGE_SIZE, offset: offset, created_date_start: start)
        end
        batch = Array(page.is_a?(Hash) ? page["content"] : page)
        trace_wise_fetch(
          operation: "transfers",
          status: "completed",
          level: "info",
          offset: offset,
          received_record_count: batch.size
        )
        break if batch.empty?

        fresh = batch.reject { |transfer| seen_ids.include?(transfer_key(transfer)) }
        raise PaginationError, "Wise transfers page at offset #{offset} repeated earlier transfers" if fresh.empty?

        fresh.each { |transfer| seen_ids << transfer_key(transfer) }
        transfers.concat(fresh)
        offset += PAGE_SIZE
      end

      Rails.logger.info "WiseItem::Importer - Fetched #{transfers.size} transfers for profile #{wise_item.profile_id}"
      transfers
    rescue => e
      record_fetch_failure("transfers", e, offset: offset)
      nil
    end

    # Wise lists a transfer under its creation date only, so a later change
    # (delivered, bounced, refunded) to an older one is read by id. A transfer
    # Wise no longer finds keeps its stored copy, which counts the syncs it
    # went missing on ("wise_missing_count", gone once Wise finds it again)
    # until MISSING_TRANSFER_REREADS stop its reads; support is told when it
    # first goes missing. nil when a read failed; the stored copies stay as
    # they are.
    def reread_transfers(except:)
      candidates = stored_transfer_rows
        .select { |row| reread_transfer?(row) && except.exclude?(row["id"].to_s) }
        .reject { |row| row["wise_missing_count"].to_i >= MISSING_TRANSFER_REREADS }
        .sort_by { |row| transfer_created_at(row) || Time.at(0) }
        .last(MAX_TRANSFER_REREADS)
        .reverse
      newly_missing = 0

      transfers = candidates.filter_map do |row|
        Provider::Wise.with_retries { wise_provider.get_transfer(row["id"]) }
      rescue Provider::Wise::WiseError => e
        raise unless e.error_type == :not_found

        newly_missing += 1 if row["wise_missing_count"].to_i.zero?
        row.merge("wise_missing_count" => row["wise_missing_count"].to_i + 1)
      end

      if newly_missing.positive?
        capture_debug_log(
          category: "provider_sync_error",
          level: "warn",
          message: "WiseItem::Importer - Wise no longer finds #{newly_missing} stored transfers; keeping their stored copies",
          operation: "transfer",
          missing_transfer_count: newly_missing
        )
      end
      transfers.select { |transfer| transfer.is_a?(Hash) && transfer["id"].present? }
    rescue => e
      record_fetch_failure("transfer", e)
      nil
    end

    def reread_transfer?(row)
      status = row["status"].to_s
      status != "outgoing_payment_sent" && FINAL_TRANSFER_STATUSES.exclude?(status)
    end

    # One copy per transfer stored on the balances that still take
    # /v1/transfers rows (no statement rows yet).
    def stored_transfer_rows
      wise_item.wise_accounts.reject(&:jar?).flat_map do |wise_account|
        rows = Array(wise_account.raw_transactions_payload)
        next [] if rows.any? { |row| row["wise_statement"].present? }

        rows.select { |row| transfer_row?(row) }
      end.uniq { |row| row["id"].to_s }
    end

    def transfer_row?(row)
      row["wise_statement"].blank? && !WiseActivity::Processor.activity_row?(row) && row["id"].present?
    end

    def transfer_key(transfer)
      transfer["id"].presence&.to_s || transfer.to_json
    end

    def transfer_created_at(row)
      WiseEntry::Processor.created_at(row)
    rescue ArgumentError
      nil
    end

    # Where this sync's fetch of `source` (:transfers or :activities) starts:
    # the whole history (#history_start) while nothing is covered, an older
    # build recorded the coverage (WiseItem::COVERAGE_VERSION) or it starts
    # later than the history (import_all_history switched on, the sync start
    # date moved back); otherwise incrementally.
    def window_start(source)
      coverage = wise_item.fetch_coverage(source)
      start = history_start
      return start if coverage.nil? || coverage[:from] > start

      if source == :transfers
        [ coverage[:through] - TRANSFER_OVERLAP, TRANSFER_RECHECK_PERIOD.ago ].min
      else
        [ coverage[:through] - ACTIVITY_OVERLAP, unfinished_activity_start ].compact.min
      end
    end

    # Where the history Sure imports starts: the given full history start,
    # unless a sync start date (the sync's or the item's) says otherwise;
    # an item that imports the whole history starts at the earlier of the
    # two. A start date is where the history starts, not where every sync
    # starts: once covered from it, syncs go on incrementally.
    def history_start(full_start = full_history_start)
      explicit = explicit_window_start
      return full_start unless explicit

      full_history? ? [ explicit, full_start ].min : explicit
    end

    # The start of the explicit sync start date in the family's zone.
    def explicit_window_start
      return @explicit_window_start if defined?(@explicit_window_start)

      date = (sync_start_date.presence || wise_item.sync_start_date.presence)&.to_date
      @explicit_window_start = date&.in_time_zone(wise_item.time_zone)
    end

    # A full-history import starts a day before Wise opened the account,
    # which predates every balance; otherwise DEFAULT_HISTORY_DAYS back.
    def full_history_start
      return DEFAULT_HISTORY_DAYS.days.ago unless full_history?

      created_at = parse_utc((@multi_currency_account || stored_multi_currency_account)&.dig("creationTime"))
      created_at ? created_at - 1.day : FULL_HISTORY_START_DATE.in_time_zone("UTC")
    end

    # A day before the oldest stored activity that can still change, so its
    # final status is fetched; activities older than the lookback are no
    # longer re-read, which is logged.
    def unfinished_activity_start
      created = stored_activity_rows
        .select { |row| row["status"].present? && FINAL_ACTIVITY_STATUSES.exclude?(row["status"]) }
        .filter_map { |row| activity_created_at(row) }
      return nil if created.empty?

      limit = UNFINISHED_ACTIVITY_LOOKBACK.ago
      aged = created.count { |time| time - 1.day < limit }
      if aged.positive? && aged_activities_unreported?(aged)
        capture_debug_log(
          category: "provider_sync",
          level: "info",
          message: "WiseItem::Importer - #{aged} unfinished Wise activities are older than #{UNFINISHED_ACTIVITY_LOOKBACK.inspect} and are no longer re-read",
          operation: "activities",
          aged_activity_count: aged
        )
      end
      [ created.min - 1.day, limit ].max
    end

    # Once a day per connection and count, the way WiseItem#time_zone reports a
    # zone it cannot use, not on every sync.
    def aged_activities_unreported?(count)
      Rails.cache.write([ "wise_aged_unfinished_activities", wise_item.id, count ], true, expires_in: 1.day, unless_exist: true)
    end

    def stored_activity_rows
      wise_item.wise_accounts
               .flat_map { |wise_account| Array(wise_account.raw_transactions_payload) }
               .select { |row| WiseActivity::Processor.activity_row?(row) }
    end

    def activity_created_at(row)
      WiseActivity::Processor.created_at(row)
    rescue ArgumentError
      nil
    end

    def record_coverage!
      wise_item.merge_sync_metadata!("coverage" => coverage_after_fetch) if @fetched_windows.any?
    end

    # The stored coverage extended by each source fetched in full this sync,
    # recorded under this build's WiseItem::COVERAGE_VERSION: `through` is
    # when that fetch started and `from` only moves earlier. A window that
    # starts after the stored `through` restarts the coverage, since the rows
    # in between were never fetched.
    def coverage_after_fetch
      stored = wise_item.sync_metadata["coverage"]
      coverage = stored.is_a?(Hash) ? stored.dup : {}
      @fetched_windows.each do |source, window|
        covered = wise_item.fetch_coverage(source)
        from = covered && window[:start] <= covered[:through] ? [ covered[:from], window[:start] ].min : window[:start]
        coverage[source.to_s] = { "from" => from.utc.iso8601, "through" => window[:through].utc.iso8601,
                                  "version" => WiseItem::COVERAGE_VERSION }
      end
      coverage
    end

    def parse_utc(raw)
      ActiveSupport::TimeZone["UTC"].parse(raw.to_s) if raw.present?
    rescue ArgumentError
      nil
    end

    # Fetches statement rows for STANDARD balances. Legacy transfer snapshots
    # are retained; outgoing statement rows dated on/after the oldest legacy
    # transfer are dropped since transfers already captured that side (see
    # #legacy_overlap_outgoing_row?), while incoming rows there are kept so
    # money the legacy fallback could never capture (external payments) gets
    # backfilled -- at the cost of occasionally re-importing the credit leg of
    # a historical internal conversion transfers also already captured (see
    # #legacy_overlap_outgoing_row? for why that trade-off is intentional).
    #
    # A 403 Sure cannot get past (#statements_refused?) means the token
    # cannot read statements this sync: the other balances without statement
    # rows are not asked, and it is logged once, not counted as a failure. A
    # balance that holds statement rows is still asked, and a 403 on it (also
    # Wise refusing a configured SCA key's answer) is no failure either:
    # nothing a later sync retries would get past it. Any other failure
    # counts against the import for a balance that holds statement rows,
    # also when the transfer fallback runs, and keeps its payload as it was
    # (#statement_retry_accounts); a balance without statement rows takes
    # its transfers and activities this sync instead (#statements_missing?).
    def fetch_statements
      @statement_fetch_attempted_accounts = []
      @statement_fetch_failed_accounts = []
      unavailable_count = 0
      refusal = nil

      statements = wise_item.wise_accounts.each_with_object({}) do |wise_account, result|
        next if wise_account.jar?

        existing = Array(wise_account.raw_transactions_payload)
        has_statement_rows = existing.any? { |transaction| transaction["wise_statement"].present? }

        if unavailable_count.positive? && !has_statement_rows
          @statement_fetch_attempted_accounts << wise_account.id
          @statement_fetch_failed_accounts << wise_account.id
          unavailable_count += 1
          result[wise_account.id] = []
          next
        end

        legacy = existing.select do |transaction|
          transaction["wise_statement"].blank? && !jar_activity?(transaction)
        end
        legacy_cutoff = legacy.filter_map { |transaction| parse_transaction_date(transaction) }.min

        start_date =
          if has_statement_rows &&
             sync_start_date.blank? && wise_item.sync_start_date.blank? && wise_item.last_synced_at.present?
            # Incremental: once statements exist, only fetch the short overlap.
            (wise_item.last_synced_at - 7.days).to_date
          elsif full_history?
            full_history_start_date(wise_account)
          else
            sync_start_date_value
          end
        end_date = Date.current

        next if start_date > end_date

        @statement_fetch_attempted_accounts << wise_account.id
        trace_wise_fetch(
          operation: "balance_statement",
          status: "started",
          level: "info",
          wise_account: wise_account,
          start_date: start_date,
          end_date: end_date
        )
        rows = wise_provider.get_balance_statements(
          wise_item.profile_id,
          wise_account.balance_id,
          currency: wise_account.currency,
          start_date: start_date,
          end_date: end_date
        )
        received_row_count = Array(rows).size
        rows = Array(rows).reject { |row| legacy_overlap_outgoing_row?(row, legacy_cutoff) }
        trace_wise_fetch(
          operation: "balance_statement",
          status: "completed",
          level: "info",
          wise_account: wise_account,
          received_row_count: received_row_count,
          stored_row_count: rows.size
        )
        result[wise_account.id] = rows.map { |row| row.merge("wise_statement" => true) }
      rescue => e
        @statement_fetch_failed_accounts << wise_account.id
        result[wise_account.id] = []
        @statements_refused_accounts << wise_account.id if has_statement_rows && statements_forbidden?(e)
        if statements_refused?(e)
          unavailable_count += 1
          refusal ||= e
        elsif has_statement_rows && !statements_forbidden?(e)
          @statement_retry_accounts << wise_account.id
          record_fetch_failure("balance_statement", e, wise_account: wise_account)
        else
          trace_wise_fetch(operation: "balance_statement", status: "failed", level: "warn", wise_account: wise_account, error: e)
        end
      end

      log_statements_unavailable(unavailable_count, refusal) if refusal
      statements
    end

    # A 403 without an SCA challenge (the token may not read statements at
    # all), or with one Sure cannot sign as no SCA key is configured
    # (Provider::Wise answers a challenge with a signed retry whenever one
    # is, so with a key a challenged 403 is Wise refusing that answer).
    def statements_refused?(error)
      return false unless statements_forbidden?(error)

      !error.sca_challenged? || wise_item.sca_private_key.blank?
    end

    def statements_forbidden?(error)
      error.is_a?(Provider::Wise::WiseError) && error.error_type == :access_forbidden
    end

    # A balance without statement rows whose statements did not arrive takes
    # its transfers and activities this sync like a balance without
    # statements, so the transfer list is fetched for it.
    def statements_missing?
      (Array(@statement_fetch_failed_accounts) - @statement_retry_accounts).any?
    end

    def log_statements_unavailable(balance_count, refusal)
      reason = refusal.sca_challenged? ? "an SCA challenge and no SCA key configured to sign it" : "no SCA challenge"
      capture_debug_log(
        category: "provider_sync",
        level: "info",
        message: "WiseItem::Importer - Wise balance statements are unavailable to this token " \
                 "(403 with #{reason}); using transfers and activities instead",
        operation: "balance_statement",
        error_type: "access_forbidden",
        sca_challenged: refusal.sca_challenged?,
        balance_count: balance_count
      )
    end

    # The legacy /v1/transfers fallback captured outgoing money unconditionally,
    # plus the incoming leg of any internal cross-currency conversion between
    # the profile's own balances (transfers where this balance is the target).
    # So an outgoing statement row (Wise reports debits as non-positive) dated
    # on/after the oldest legacy transfer already has a legacy counterpart and
    # would double-book it.
    #
    # An incoming row in that same window *could* be the credit leg of one of
    # those internal conversions (also already covered) rather than a genuine
    # external payment -- but nothing short of an endpoint-proven correlation
    # id can tell the two apart without risk of a false match, and silently
    # dropping a real external payment is a worse failure than an occasional
    # visible, user-correctable duplicate for a historical conversion. So
    # incoming rows are always kept here; #legacy_transfer_import_needed?
    # instead bounds the exposure by stopping the transfer fallback (and with
    # it, any *new* double-booking) as soon as an account's statements prove
    # to work.
    def legacy_overlap_outgoing_row?(row, legacy_cutoff)
      return false unless legacy_cutoff

      date = parse_transaction_date(row)
      return false unless date && date >= legacy_cutoff

      row.dig("amount", "value").to_d <= 0
    end

    # Statements are only "unavailable" when every attempted standard balance
    # request failed (e.g. the token lacks statement access). Successful
    # requests that return zero rows are normal — quiet incremental syncs must
    # not re-enable the transfer fallback, which would duplicate movements that
    # are already imported as statement rows.
    def statement_fetches_failed_completely?
      attempted = Array(@statement_fetch_attempted_accounts)
      failed = Array(@statement_fetch_failed_accounts)
      attempted.any? && (attempted - failed).empty?
    end

    # The transfer endpoint remains a compatibility fallback only until an
    # account's statements are proven to work: once a statement row has
    # landed for an account, statements alone cover both directions of money
    # movement going forward, so re-fetching transfers would only re-invite
    # double-booking new internal conversions (see #legacy_overlap_outgoing_row?)
    # for no benefit.
    def legacy_transfer_import_needed?
      wise_item.wise_accounts.any? do |wise_account|
        next false if wise_account.jar?

        payload = Array(wise_account.raw_transactions_payload)
        has_legacy = payload.any? { |transaction| transaction["wise_statement"].blank? && !jar_activity?(transaction) }
        has_statement = payload.any? { |transaction| transaction["wise_statement"].present? }

        has_legacy && !has_statement
      end
    end

    # Partitions transactions by the currency relevant to each WiseAccount:
    # - Expenses (outgoing): matched by sourceCurrency
    # - Incomes (incoming): matched by targetCurrency
    # Routes transfers to STANDARD accounts and activities to JAR accounts.
    def store_transfers_per_account(transfers, activities: [], statements: {}, statement_failures: [], fallback_to_transfers: false)
      transactions_imported = 0
      transactions_failed = 0

      wise_item.wise_accounts.find_each do |wise_account|
        # A failed statement request for a balance that holds statement rows
        # (without a transfer fallback) leaves the account incomplete: keep
        # its existing payload and surface the failure so the item is not
        # marked good.
        if statement_failures.include?(wise_account.id) && !fallback_to_transfers
          transactions_failed += 1
          next
        end

        if wise_account.jar?
          jar_activities = activities.select { |a| activity_for_account?(a, wise_account) }
          # Merged, never replaced: this sync's window (or a failed fetch)
          # holds only part of the jar's history, and a jar is only linked
          # after the sync that first stored it.
          payload = merge_transaction_payloads(Array(wise_account.raw_transactions_payload) + jar_activities)
          wise_account.upsert_wise_transactions_snapshot!(payload)
          transactions_imported += payload.size
        else
          account_statements = statements[wise_account.id] || []
          # Stored activities are re-routed too, so snapshots saved before
          # INTERBALANCE routing honored currency drop rows for other balances.
          existing_legacy = Array(wise_account.raw_transactions_payload).reject do |transaction|
            next true if transaction["wise_statement"].present?

            if jar_activity?(transaction)
              !activity_for_account?(transaction, wise_account)
            else
              !transfer_for_account?(transaction, wise_account)
            end
          end
          existing_statements = Array(wise_account.raw_transactions_payload).select { |transaction| transaction["wise_statement"].present? }
          # `transfers` is fetched profile-wide as soon as ANY account still
          # needs the legacy fallback (see #legacy_transfer_import_needed?),
          # so it can contain movements for a currency this specific account
          # already covers via its own statements. Only apply it here if this
          # account hasn't migrated yet -- otherwise the same movement would
          # be merged twice under different keys (see #merge_transaction_payloads).
          account_transfers =
            if existing_statements.any?
              []
            else
              transfers.select { |t| transfer_for_account?(t, wise_account) }
            end
          # Also include INTERBALANCE activities so the standard account shows outflows to the JAR.
          interbalance = activities.select { |a| activity_for_account?(a, wise_account) }
          payload = merge_transaction_payloads(
            existing_legacy + account_transfers + existing_statements + account_statements + interbalance
          )
          # A statement request can legitimately return no rows for a token
          # lacking statement permission; preserve transfer fallback behavior.
          payload = merge_transaction_payloads(account_transfers + interbalance) if payload.empty?
          wise_account.upsert_wise_transactions_snapshot!(payload)
          transactions_imported += payload.size
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "WiseItem::Importer - Failed to store transactions for wise_account #{wise_account.id}: #{e.message}"
      end

      { transactions_imported: transactions_imported, transactions_failed: transactions_failed }
    end

    # An outgoing transfer only touches the balance it was paid from, and an
    # incoming one only the balance it landed in. Matching either currency
    # would also book e.g. a GBP-funded payout in PLN on the PLN balance.
    def transfer_for_account?(transfer, wise_account)
      outgoing = WiseEntry::Processor.outgoing?(
        transfer,
        recipient_id: wise_account.raw_payload&.dig("recipient_id"),
        balance_recipient_id: wise_account.raw_payload&.dig("recipientId")
      )
      currency = outgoing ? transfer["sourceCurrency"] : transfer["targetCurrency"]
      currency.blank? || currency == wise_account.currency
    end

    def merge_transaction_payloads(transactions)
      transactions.each_with_object({}) do |transaction, merged|
        key = if transaction["wise_statement"].present?
          [ "statement", transaction["referenceNumber"].presence || transaction["id"] || transaction.to_json ]
        elsif transaction["type"].present?
          [ "activity", transaction["id"] || transaction.to_json ]
        else
          [ "transfer", transaction["id"] || transaction.to_json ]
        end
        merged[key] = transaction
      end.values
    end

    def jar_activity?(transaction)
      WiseActivity::Processor::JAR_ACTIVITY_TYPES.include?(transaction["type"])
    end

    # A source that failed to arrive in full: logged for support and counted,
    # so the import is neither successful nor complete and its coverage stays.
    def record_fetch_failure(operation, error, level: "warn", **metadata)
      @fetch_failures += 1
      trace_wise_fetch(operation: operation, status: "failed", level: level, error: error, **metadata)
    end

    def trace_wise_fetch(operation:, status:, level:, wise_account: nil, error: nil, **metadata)
      message = "WiseItem::Importer - Wise #{operation} fetch #{status}"
      message = "#{message} for wise_account #{wise_account.id}" if wise_account
      message = "#{message}: #{error.message}" if error

      return Rails.logger.debug(message) unless error

      Rails.logger.public_send(level, message)
      capture_debug_log(
        category: "provider_sync_error",
        level: level,
        message: message,
        wise_account: wise_account,
        operation: operation,
        error_class: error.class.name,
        error_type: error.respond_to?(:error_type) ? error.error_type : nil,
        **metadata
      )
    end

    def capture_debug_log(category:, level:, message:, wise_account: nil, **metadata)
      DebugLogEntry.capture(
        category: category,
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "wise",
        family: wise_item.family,
        account_provider: wise_account&.account_provider,
        metadata: {
          wise_item_id: wise_item.id,
          wise_account_id: wise_account&.id,
          balance_id: wise_account&.balance_id,
          currency: wise_account&.currency,
          sca_private_key_configured: wise_item.sca_private_key.present?
        }.merge(metadata).compact
      )
    rescue => trace_error
      Rails.logger.warn "WiseItem::Importer - Failed to capture Wise debug log: #{trace_error.message}"
    end

    # Routes an activity to the given WiseAccount.
    # JAR: receives INTERBALANCE where the activity title's <strong> tag matches the JAR name,
    #      plus BALANCE_CASHBACK and BALANCE_ASSET_FEE.
    # STANDARD: receives INTERBALANCE activities that move money in its own
    #      currency: the outflow side of JAR transfers, and either side of a
    #      currency conversion between the profile's balances. Activities are
    #      fetched profile-wide, so without this filter every balance would show
    #      every conversion in some other currency.
    def activity_for_account?(activity, wise_account)
      type = activity["type"]

      case type
      when "INTERBALANCE"
        if wise_account.jar?
          jar_title_match?(activity, wise_account)
        else
          standard_interbalance_for_account?(activity, wise_account)
        end
      when "BALANCE_ASSET_FEE", "BALANCE_CASHBACK"
        wise_account.jar?
      else
        false
      end
    end

    def standard_interbalance_for_account?(activity, wise_account)
      conversion = WiseActivity::Processor.conversion_currencies(activity)

      if conversion
        return true if conversion[:source] == wise_account.currency
        # A cross-currency move into a JAR has no STANDARD target side.
        conversion[:target] == wise_account.currency &&
          wise_item.wise_accounts.none? { |other| other.jar? && jar_title_match?(activity, other) }
      else
        currency = WiseActivity::Processor.parse_money(activity["primaryAmount"]).last
        currency.blank? || currency == wise_account.currency
      end
    end

    def jar_title_match?(activity, jar_account)
      jar_name_in_title = activity["title"].to_s.scan(/<strong>([^<]+)<\/strong>/).flatten.last.to_s.strip
      jar_name_in_title.present? && jar_name_in_title.casecmp?(jar_account.name.to_s.strip)
    end

    def sync_start_date_value
      (sync_start_date.presence || wise_item.sync_start_date.presence || DEFAULT_HISTORY_DAYS.days.ago).to_date
    end

    def full_history?
      wise_item.import_all_history?
    end

    # Full-history imports start from the balance's creation time when Wise
    # reports one, falling back to a far-past date so every historical row is
    # fetched regardless.
    def full_history_start_date(wise_account)
      raw = wise_account.raw_payload&.dig("creationTime")
      return FULL_HISTORY_START_DATE if raw.blank?

      Time.parse(raw.to_s).to_date
    rescue ArgumentError, TypeError
      FULL_HISTORY_START_DATE
    end

    def parse_transaction_date(transaction)
      raw = transaction["created"] || transaction["createdOn"] || transaction["date"]
      return nil if raw.blank?

      Time.parse(raw.to_s).to_date
    rescue ArgumentError, TypeError
      nil
    end

    def credentials_error?(error)
      error.is_a?(Provider::Wise::WiseError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
    end

    def mark_requires_update_if_credentials_error(error)
      return unless credentials_error?(error)

      wise_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "WiseItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      {
        success: false,
        complete: false,
        fetch_failures: [ @fetch_failures, 1 ].max,
        error: error,
        accounts_created: 0,
        accounts_updated: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end
end
