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
  # A balance's statements are fetched again from a week before the end of
  # its last successful statement fetch.
  STATEMENT_OVERLAP = 7.days

  # A transfer in one of these statuses no longer changes. Stored transfers
  # in any other status but outgoing_payment_sent (which the 60-day window
  # re-lists) are read again by id each sync, newest first, and so is a sent
  # payout once a refund credit for it shows up.
  FINAL_TRANSFER_STATUSES = %w[cancelled funds_refunded charged_back].freeze
  MAX_TRANSFER_REREADS = 50
  # A stored transfer Wise no longer finds by id is read again on this many
  # syncs ("wise_missing_count" on its stored copy), then left as stored.
  MISSING_TRANSFER_REREADS = 3

  # What Sure attaches to a stored transfer row: the activity Wise shows for
  # the transfer and the refund credit of a refunded payout.
  ENRICHMENT_KEYS = %w[wise_activity wise_refund_activity].freeze
  # A re-fetched copy of a row keeps what Sure attached to the stored copy
  # unless it brings its own, so a sync whose activities do not reach that
  # far back (or failed) loses nothing: the enrichment, the balance replay's
  # marks, which only the replay changes (WiseItem::BalanceReplay), and the
  # id a statement row booked under (WiseItem::StatementMigration).
  STICKY_ROW_KEYS = (ENRICHMENT_KEYS + WiseItem::BalanceReplay::ANNOTATION_KEYS + %w[wise_statement_id]).freeze
  MAX_LOGGED_TRANSFER_IDS = 20

  # Where a jar move, or interest or a fee on holdings, was first routed:
  # the Wise balance id of its jar (for interest and fees, of whichever
  # balance took them). Written on every stored copy and honoured from then
  # on, so a jar renamed in Wise, a second jar in the currency or a jar
  # opened later moves nothing already routed (#routing_decision).
  ROUTING_DECISION_KEY = "wise_jar_balance_id"
  # A balance in one of these states holds investments, which earn interest
  # and fees like a jar.
  INVESTED_STATES = %w[INVESTED INVESTING DIVESTING].freeze

  # Wise answered with a page this fetch had already read.
  PaginationError = Class.new(StandardError)

  # How many syncs in a row both balance lists must arrive in full without a
  # stored balance before Sure takes it as closed.
  CLOSURE_ABSENCES = 2

  attr_reader :wise_item, :wise_provider, :sync_start_date

  def initialize(wise_item, wise_provider:, sync_start_date: nil)
    @wise_item = wise_item
    @wise_provider = wise_provider
    @sync_start_date = sync_start_date
    @fetch_failures = 0
    @fetched_windows = {}
    @coverage_upgrade_sources = Set.new
    @statement_windows = {}
    @statement_coverage_upgrades = Set.new
    @known_transfer_ids = Set.new
    @statement_covered_account_ids = Set.new
    @statement_cutoffs = {}
    @statement_retry_accounts = []
    @statements_refused_accounts = []
    @deferred_activity_times = []
    @live_amounts = {}
  end

  # `complete:` is true only when every source this sync needed arrived in
  # full: balances, transfers and their re-reads, activities, and statements
  # of balances that already hold statement rows. Steps that delete or
  # rewrite entries must not run after an incomplete import.
  # `coverage_upgraded:` see #coverage_upgraded? (for support and tests: the
  # balances it rebuilt keep what it means for them themselves,
  # WiseAccount#prune_cap_bypass_ids).
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
    track_closed_balances(all_balances)

    transfers = fetch_transfers if legacy_transfer_import_needed?
    activities = fetch_activities
    statements = fetch_statements
    statement_fallbacks = statement_fetches_failed_completely?
    transfers = fetch_transfers if (statement_fallbacks || statements_missing?) && !@transfers_attempted
    @live_amounts = fetch_live_amounts(balances) if balance_replay_wanted?(balances)
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
      coverage_upgraded: coverage_upgraded?,
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

    # Wise lists only the balances a profile has now, and closes only empty
    # ones. A stored balance missing from both lists, arrived in full, in
    # CLOSURE_ABSENCES syncs in a row is closed: marked closed_at and set to
    # 0 (once; Wise no longer reports it), which freezes its payload (see
    # #store_transfers_per_account) and stops its statements. One the lists
    # show again is open again. A failed or partial list proves nothing, so
    # it counts no absence.
    def track_closed_balances(listed_balances)
      listed_ids = Array(listed_balances).filter_map { |balance| balance["id"].presence&.to_s if balance.is_a?(Hash) }.to_set
      complete = balance_lists_complete?
      changed = false

      WiseAccount.where(wise_item_id: wise_item.id).find_each do |wise_account|
        payload = wise_account.raw_payload.is_a?(Hash) ? wise_account.raw_payload : {}
        changed |=
          if listed_ids.include?(wise_account.balance_id.to_s)
            reopen_balance(wise_account, payload)
          elsif complete && payload["closed_at"].blank?
            count_balance_absence(wise_account, payload)
          else
            false
          end
      rescue => e
        Rails.logger.error "WiseItem::Importer - Failed to track whether balance #{wise_account.id} is closed: #{e.message}"
      end

      # Later reads of the item's balances see the marks.
      wise_item.wise_accounts.reset if changed
    end

    # Clears the absence count and closure of a balance Wise lists.
    def reopen_balance(wise_account, payload)
      return false unless payload.key?("closed_at") || payload.key?("absent_count")

      wise_account.update!(raw_payload: payload.except("closed_at", "absent_count"))
      if payload["closed_at"].present?
        capture_debug_log(category: "provider_sync", level: "info", wise_account: wise_account, operation: "balances",
                          message: "WiseItem::Importer - Wise lists a balance Sure had marked closed again; it is open again")
      end
      true
    end

    def count_balance_absence(wise_account, payload)
      absences = payload["absent_count"].to_i + 1
      if absences < CLOSURE_ABSENCES
        wise_account.update!(raw_payload: payload.merge("absent_count" => absences))
      else
        wise_account.update!(current_balance: 0, reserved_balance: 0,
                             raw_payload: payload.merge("absent_count" => absences, "closed_at" => Time.current.utc.iso8601))
        capture_debug_log(category: "provider_sync", level: "info", wise_account: wise_account, operation: "balances",
                          message: "WiseItem::Importer - Wise no longer lists a balance; Sure marks it closed at 0",
                          absent_count: absences)
      end
      true
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
    # The recipient is the fallback for the multi-currency account's, one of
    # the profile's own recipients that tell a pay-in from a payout
    # (WiseItem#own_recipient_ids).
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
        .select { |row| reread_transfer?(row) && row["wise_superseded_by"].blank? && except.exclude?(row["id"].to_s) }
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

    # A payout Wise refunds after the window stopped re-listing it is read
    # again once its refund credit is on its row (from the sync that saw the
    # credit on), so its new status books the refund.
    def reread_transfer?(row)
      status = row["status"].to_s
      return false if FINAL_TRANSFER_STATUSES.include?(status)

      status != "outgoing_payment_sent" || WiseEntry::Processor.refund(row).present?
    end

    # One copy per transfer stored on the STANDARD balances, statement-
    # covered ones included: a transfer their statement rows have not taken
    # over yet still books from its row (WiseItem::StatementMigration), so
    # it is read again like any other (#reread_transfers skips the rest).
    def stored_transfer_rows
      wise_item.wise_accounts.reject(&:jar?).flat_map do |wise_account|
        Array(wise_account.raw_transactions_payload).select { |row| transfer_row?(row) }
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
      if coverage.nil? || coverage[:from] > start
        @coverage_upgrade_sources << source
        return start
      end

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

    # Whether a source arrived in full for the first time (an install from
    # before coverage was kept) or from the start of the whole history its
    # coverage did not reach (the full history switched on), transfers and
    # activities or a balance's statements (#statement_coverage_upgrade?):
    # the payloads were rebuilt from a complete fetch, so the stale entry
    # clean-up may exceed its cap for the rows that moved (#prune_cap_bypass_to_store).
    def coverage_upgraded?
      @coverage_upgrade_sources.any? { |source| @fetched_windows.key?(source) } || @statement_coverage_upgrades.any?
    end

    # Transfers and activities feed every balance; a balance's statements
    # only that balance.
    def coverage_upgraded_for?(wise_account)
      @coverage_upgrade_sources.any? { |source| @fetched_windows.key?(source) } ||
        @statement_coverage_upgrades.include?(wise_account.id)
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
        through = source == :activities ? [ window[:through], deferred_activity_cutoff ].compact.min : window[:through]
        coverage[source.to_s] = { "from" => from.utc.iso8601, "through" => through.utc.iso8601,
                                  "version" => WiseItem::COVERAGE_VERSION }
      end
      coverage
    end

    # A credit this sync deferred (#transfer_activity_route) is booked by a
    # later sync, which must read it again: activity coverage ends a day
    # before the oldest one, so the next window reaches back to it. Not when
    # this sync asked for no transfer list at all (statements carry the
    # movements): no later sync is sure to list transfers either, and the
    # window would only grow.
    def deferred_activity_cutoff
      oldest = @deferred_activity_times.compact.min if @transfers_attempted
      oldest - 1.day if oldest
    end

    def parse_utc(raw)
      ActiveSupport::TimeZone["UTC"].parse(raw.to_s) if raw.present?
    rescue ArgumentError
      nil
    end

    # Fetches statement rows for STANDARD balances, each from its own
    # coverage (#statement_window_start) until now, as UTC instants. Every
    # row is kept: rows a balance booked before it had statements (its
    # /v1/transfers and activity rows) hand their movements over to the
    # statement rows that carry them (WiseItem::StatementMigration).
    #
    # A 403 Sure cannot get past (#statements_refused?) means the token
    # cannot read statements this sync: the other balances without statement
    # rows are not asked, and it is logged once, not counted as a failure. A
    # balance that holds statement rows is still asked, and a 403 on it (also
    # Wise refusing a configured SCA key's answer) is no failure either:
    # nothing a later sync retries would get past it. The balance then takes
    # what happened after its statements last reached from transfers and
    # activities (#statement_covered?). Any other failure
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
        # A closed balance has no statements to fetch any more.
        next if wise_account.jar? || wise_account.closed?

        has_statement_rows = Array(wise_account.raw_transactions_payload).any? { |transaction| transaction["wise_statement"].present? }

        if unavailable_count.positive? && !has_statement_rows
          @statement_fetch_attempted_accounts << wise_account.id
          @statement_fetch_failed_accounts << wise_account.id
          unavailable_count += 1
          result[wise_account.id] = []
          next
        end

        started_at = Time.current
        interval_start = statement_window_start(wise_account)
        next if interval_start > started_at

        @statement_fetch_attempted_accounts << wise_account.id
        trace_wise_fetch(
          operation: "balance_statement",
          status: "started",
          level: "info",
          wise_account: wise_account,
          interval_start: interval_start,
          interval_end: started_at
        )
        rows = wise_provider.get_balance_statements(
          wise_item.profile_id,
          wise_account.balance_id,
          currency: wise_account.currency,
          interval_start: interval_start,
          interval_end: started_at
        )
        rows = Array(rows).map { |row| row.merge("wise_statement" => true) }.uniq { |row| statement_key(row) }
        trace_wise_fetch(
          operation: "balance_statement",
          status: "completed",
          level: "info",
          wise_account: wise_account,
          received_row_count: rows.size
        )
        @statement_windows[wise_account.id] = { start: interval_start, through: started_at }
        @statement_coverage_upgrades << wise_account.id if statement_coverage_upgrade?(wise_account)
        check_running_balances(wise_account, rows)
        result[wise_account.id] = rows
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

    # Where this sync's statement fetch for a balance starts, from the
    # balance's own coverage, like #window_start for transfers and
    # activities: the whole history (#statement_history_start) while
    # nothing is covered or the coverage starts later (the full history
    # switched on, the sync start date moved back); otherwise a week before
    # the end of the last successful fetch, so a statement outage leaves no
    # gap. Statement rows are kept whatever the build, so their coverage
    # has no version.
    def statement_window_start(wise_account)
      coverage = wise_account.statements_coverage
      start = statement_history_start(wise_account)
      return start if coverage.nil? || coverage[:from] > start

      coverage[:through] - STATEMENT_OVERLAP
    end

    def statement_history_start(wise_account)
      history_start(statement_full_start(wise_account))
    end

    # A full-history import fetches a balance's statements from the moment
    # Wise opened it, else from where transfers and activities start.
    def statement_full_start(wise_account)
      (full_history? && wise_account.creation_time) || full_history_start
    end

    # Whether this sync's statements rebuild a balance's stored rows from its
    # first coverage or from the whole history its coverage did not reach
    # (see #coverage_upgraded?).
    def statement_coverage_upgrade?(wise_account)
      return false if Array(wise_account.raw_transactions_payload).empty?

      coverage = wise_account.statements_coverage
      coverage.nil? || coverage[:from] > statement_history_start(wise_account)
    end

    # The balance's statement coverage ({ from:, through: } UTC times)
    # extended by this sync's fetch, else as stored: `from` only moves
    # earlier, unless the fetch started after the stored `through` (see
    # #coverage_after_fetch).
    def statement_coverage(wise_account)
      stored = wise_account.statements_coverage
      window = @statement_windows[wise_account.id]
      return stored unless window

      from = stored && window[:start] <= stored[:through] ? [ stored[:from], window[:start] ].min : window[:start]
      { from: from, through: window[:through] }
    end

    # What is saved with the rows a balance's statement fetch brought this
    # sync (raw_payload "statements_coverage"); nil when it fetched none.
    def statements_coverage_to_store(wise_account)
      return nil unless @statement_windows.key?(wise_account.id)

      statement_coverage(wise_account).transform_keys(&:to_s).transform_values { |time| time.utc.iso8601 }
    end

    # Each statement row carries the balance after it (runningBalance), so
    # consecutive rows chain: previous + amount = running. A break suggests
    # Sure reads the amounts wrongly (a credit's amount is taken as already
    # net of its fee), so it is logged for support: counts only, and how
    # many breaks the row's own fee would explain. Rows at the same time may
    # come in any order, so a row chains from any row of its own time or of
    # the time before; the earliest time has its predecessor outside the
    # window and is not checked.
    def check_running_balances(wise_account, rows)
      groups = rows.filter_map do |row|
        posted_at = WiseStatement::Processor.posted_at(row)
        [ posted_at, row ] if posted_at && row.dig("runningBalance", "value").present? && row.dig("amount", "value").present?
      end.group_by(&:first).sort_by(&:first).map { |_time, pairs| pairs.map(&:last) }

      breaks = 0
      fee_explained = 0
      groups.each_cons(2) do |previous, group|
        group.each do |row|
          gaps = (previous + group.reject { |other| other.equal?(row) }).map do |before|
            row.dig("runningBalance", "value").to_d - before.dig("runningBalance", "value").to_d - row.dig("amount", "value").to_d
          end
          next if gaps.any? { |gap| gap.abs <= WiseItem::StatementMigration::TOLERANCE }

          breaks += 1
          fee = row.dig("totalFees", "value").to_d
          fee_explained += 1 if fee.positive? && gaps.any? { |gap| (gap.abs - fee).abs <= WiseItem::StatementMigration::TOLERANCE }
        end
      end
      return if breaks.zero?

      capture_debug_log(
        category: "provider_sync",
        level: "warn",
        message: "WiseItem::Importer - #{breaks} Wise statement rows do not follow on from the running balance before them",
        wise_account: wise_account,
        operation: "running_balance",
        row_count: groups.sum(&:size),
        break_count: breaks,
        fee_explained_count: fee_explained
      )
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

    # Transfers are fetched ahead of the statements while a balance still
    # books /v1/transfers rows: one without statement rows yet, or one whose
    # statements have not taken over every transfer that books inside their
    # window (WiseItem::StatementMigration keeps those rows, which are read
    # again, until a statement row carries them).
    def legacy_transfer_import_needed?
      wise_item.wise_accounts.any? { |wise_account| legacy_transfers_pending?(wise_account) }
    end

    def legacy_transfers_pending?(wise_account)
      return false if wise_account.jar?

      payload = Array(wise_account.raw_transactions_payload)
      legacy = payload.select { |transaction| transfer_row?(transaction) }
      return false if legacy.empty?
      return true if payload.none? { |transaction| transaction["wise_statement"].present? }

      window = wise_account.statements_coverage
      window.present? && legacy.any? { |transfer| transfer["wise_superseded_by"].blank? && books_since?(transfer, window[:from]) }
    end

    # Whether a transfer row books and was created at `from` or later.
    def books_since?(transfer, from)
      created_at = transfer_created_at(transfer)
      direction = WiseEntry::Processor.direction(transfer, own_recipient_ids: own_recipient_ids)
      created_at.present? && created_at >= from && WiseEntry::Processor.skip_reason(transfer, direction: direction).nil?
    end

    # Partitions transactions by the balance each one moved money on (see
    # #transfer_for_account? and #activity_for_account?): transfers and
    # statement rows go to STANDARD balances, activities to the balances they
    # moved money on, jars included. Transfers, fetched or stored, first get
    # the activity this sync saw for them. The balance replay then marks the
    # merged payloads (#annotate_with_balance_replay) before they are stored.
    def store_transfers_per_account(transfers, activities: [], statements: {}, statement_failures: [], fallback_to_transfers: false)
      transactions_imported = 0
      transactions_failed = 0
      transfer_activities = transfer_activities_by_id(activities)
      stored_transfers = stored_transfer_rows.index_by { |row| row["id"].to_s }
      transfers = transfers.map { |transfer| enrich_transfer(transfer, transfer_activities) }
      report_transfer_notes(transfers, stored_transfers, transfer_activities)
      @known_transfer_ids = known_transfer_ids(transfers)
      @statement_covered_account_ids = statement_covered_account_ids(statements)
      @statement_cutoffs = statement_cutoffs
      @deferred_activity_times = activities.select { |activity| activity_route(activity) == :deferred }.map { |activity| activity_created_at(activity) }
      report_activity_routing(activities)
      payloads = {}

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
          stored_rows = Array(wise_account.raw_transactions_payload)
          # Merged, never replaced: this sync's window (or a failed fetch)
          # holds only part of the jar's history, and a jar is only linked
          # after the sync that first stored it. Its stored rows are routed
          # again like new ones, which keeps every row on the jar it first
          # went to (#routing_decision) and drops rows an older rule copied
          # to every jar; a closed jar's stay as they are.
          unless wise_account.closed?
            stored_rows = stored_rows.select { |row| activity_for_account?(row, wise_account, stored: true) }.map { |row| with_routing_decision(row) }
          end
          jar_activities = activities.select { |a| activity_for_account?(a, wise_account) }.map { |a| with_routing_decision(a) }
          payloads[wise_account] = merge_transaction_payloads(stored_rows + jar_activities)
        else
          covered = @statement_covered_account_ids.include?(wise_account.id)
          stored_rows = Array(wise_account.raw_transactions_payload)
          account_statements = statements[wise_account.id] || []
          # Stored rows are re-routed too, so rows saved under an older
          # routing rule (an INTERBALANCE for another currency, the funding
          # side of a pay-in) drop out. A closed balance's stored rows stay
          # as they are: nothing Wise still lists can show they belong
          # elsewhere, and its entries are no longer pruned. A balance's
          # statements do not drop its stored activities here: they are
          # handed over to the statement rows (#hand_over_to_statements).
          existing_legacy = stored_rows.filter_map do |transaction|
            next if transaction["wise_statement"].present?

            if WiseActivity::Processor.activity_row?(transaction)
              next transaction if wise_account.closed?

              with_routing_decision(transaction) if activity_for_account?(transaction, wise_account, stored: true, ignore_statements: true)
            else
              transfer = enrich_transfer(transaction, transfer_activities)
              transfer if wise_account.closed? || transfer_for_account?(transfer, wise_account)
            end
          end
          existing_statements = WiseItem::StatementMigration.with_booked_ids(stored_rows.select { |transaction| transaction["wise_statement"].present? })
          # `transfers` is fetched profile-wide while any balance still books
          # them (#legacy_transfer_import_needed?). A balance with statements
          # takes no new one its statement rows carry (#statement_covered?);
          # it takes fresh copies of the rows it still holds.
          account_transfers = transfers.select { |t| transfer_for_account?(t, wise_account) }
          if covered
            held = existing_legacy.filter_map { |transaction| transaction["id"].to_s if transfer_row?(transaction) }.to_set
            account_transfers = account_transfers.select do |t|
              held.include?(t["id"].to_s) || !statement_covered?(wise_account) { transfer_created_at(t) }
            end
          end
          routed_activities = activities.select { |a| activity_for_account?(a, wise_account) }.map { |a| with_routing_decision(a) }
          payload = merge_transaction_payloads(
            existing_legacy + account_transfers + existing_statements + account_statements + routed_activities
          )
          payload = hand_over_to_statements(wise_account, payload) if covered && !wise_account.closed?
          payloads[wise_account] = payload
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "WiseItem::Importer - Failed to store transactions for wise_account #{wise_account.id}: #{e.message}"
      end

      # Each balance in its own savepoint, so one that fails to save keeps its
      # old payload without holding back the others, except that the balances
      # whose split marks the replay changed are stored all or none: the
      # copies of a split payment on several balances carry the same parts.
      item_ids = coverage_upgraded? ? payloads.values.flatten.flat_map { |row| booked_external_ids(row) }.to_set : Set.new
      WiseAccount.transaction do
        changed, unchanged = annotate_with_balance_replay(payloads).partition do |wise_account, payload|
          split_marks_changed?(wise_account, payload)
        end
        [ changed, *unchanged.map { |pair| [ pair ] } ].reject(&:empty?).each do |group|
          WiseAccount.transaction(requires_new: true) do
            group.each do |wise_account, payload|
              wise_account.upsert_wise_transactions_snapshot!(payload, statements_coverage: statements_coverage_to_store(wise_account),
                                                                       prune_cap_bypass: prune_cap_bypass_to_store(wise_account, item_ids))
            end
          end
          transactions_imported += group.sum { |_wise_account, payload| payload.size }
        rescue => e
          transactions_failed += group.size
          Rails.logger.error "WiseItem::Importer - Failed to store transactions for wise_accounts #{group.map { |wise_account, _payload| wise_account.id }.join(', ')}: #{e.message}"
        end
      end

      { transactions_imported: transactions_imported, transactions_failed: transactions_failed }
    end

    # A sync that rebuilt the payloads from a whole history (#coverage_upgraded_for?)
    # can leave more stale entries than the clean-up deletes at once: what an
    # older build booked from rows this one routes elsewhere or books another
    # way (a conversion's copy on every balance, interest copied to every
    # jar, a payout Wise cancelled), and the entries of rows handed over to
    # statement rows or that book nothing here now. The balance's entries a
    # row Sure holds can have booked (#booked_external_ids of the balance's
    # stored rows and of every payload this sync stores, item_ids), added to
    # what an earlier such sync left, are kept on the balance until a
    # clean-up after a complete import has used them (WiseAccount
    # #prune_cap_bypass_ids); an entry no row explains stays under the cap.
    # nil when this sync adds nothing.
    def prune_cap_bypass_to_store(wise_account, item_ids)
      return nil unless coverage_upgraded_for?(wise_account)

      account = wise_account.current_account
      return nil unless account

      explained = item_ids | Array(wise_account.raw_transactions_payload).flat_map { |row| booked_external_ids(row) }
      ids = account.entries.where(source: "wise").pluck(:external_id).select { |external_id| explained.include?(external_id) }
      wise_account.prune_cap_bypass_ids | ids if ids.any?
    end

    # The external ids of every entry a stored row can have booked on a
    # balance, whichever side or kind the row processors gave it.
    def booked_external_ids(row)
      if row["wise_statement"].present?
        id = "wise_statement_#{WiseStatement::Processor.transaction_id(row)}"
        [ id, "#{id}_fee" ]
      elsif WiseActivity::Processor.activity_row?(row)
        resource_id = row["resource"]["id"] if row["resource"].is_a?(Hash)
        if WiseActivity::Processor::TWO_LEG_TYPES.include?(row["type"].to_s)
          resource_id.present? ? %w[inflow outflow].map { |side| "wise_interbalance_#{resource_id}_#{side}" } : []
        else
          row["id"].present? ? [ "wise_activity_#{row['id']}" ] : []
        end
      elsif row["id"].present?
        %w[transfer fee refund].map { |kind| "wise_#{kind}_#{row['id']}" }
      else
        []
      end
    end

    # The rows a balance with statements booked before it had them hand their
    # movements over to the statement rows that carry them, and its statement
    # rows of conversions give way to the conversions' own rows
    # (WiseItem::StatementMigration).
    def hand_over_to_statements(wise_account, payload)
      migration = WiseItem::StatementMigration.new(
        wise_account, payload,
        own_recipient_ids: own_recipient_ids,
        window: statement_coverage(wise_account),
        entry_ids: entry_ids_lookup(wise_account)
      ).call
      report_statement_migration(wise_account, migration.counts)
      migration.rows
    end

    # Which of the given external ids the balance's account has Wise entries
    # for; nil while the balance is not linked.
    def entry_ids_lookup(wise_account)
      account = wise_account.current_account
      return nil unless account

      ->(external_ids) { external_ids.empty? ? [] : account.entries.where(source: "wise", external_id: external_ids).pluck(:external_id) }
    end

    # Tells support, per balance and sync, what has no statement row yet:
    # transfers that book inside the statements' window (their rows keep
    # booking and transfers are still fetched for the balance) and dropped
    # activities (a statement row carries their movement under another
    # reference), and which rows left once their entries were renamed.
    def report_statement_migration(wise_account, counts)
      return if counts.values_at(:transfers_unmatched, :activities_unmatched, :retired).all?(&:zero?)

      capture_debug_log(
        category: "provider_sync",
        level: (counts[:transfers_unmatched] + counts[:activities_unmatched]).positive? ? "warn" : "info",
        message: "WiseItem::Importer - Wise statement rows took over #{counts[:transfers_matched]} transfers and " \
                 "#{counts[:activities_matched]} activities; #{counts[:transfers_unmatched]} transfers inside the statements' " \
                 "window have no statement row yet and keep booking, #{counts[:activities_unmatched]} activities without one were dropped",
        wise_account: wise_account,
        operation: "statement_migration",
        **counts
      )
    end

    # Replays the balances that can be replayed (#balances_to_replay) and puts
    # what it found on their rows: "wise_funding" on the transfers of each
    # balance that reconciled, "wise_split_parts" (and "wise_split_estimated")
    # on every copy of a split payment whose balances all reconciled. Rows of
    # any other balance keep their marks. A replay that raises changes nothing
    # and never fails the import.
    def annotate_with_balance_replay(payloads)
      balances = balances_to_replay(payloads)
      return payloads if balances.empty?

      # A savepoint, so a failed rate lookup cannot abort the transaction.
      result = WiseAccount.transaction(requires_new: true) do
        WiseItem::BalanceReplay.new(balances, own_recipient_ids: own_recipient_ids, feed: payloads.values.flatten).call
      end
      annotated = apply_balance_replay(payloads, result)
      report_balance_replay(result, payloads, annotated)
      annotated
    rescue => e
      Rails.logger.error "WiseItem::Importer - Wise balance replay failed: #{e.class} - #{e.message}"
      capture_debug_log(
        category: "provider_sync_error",
        level: "error",
        message: "WiseItem::Importer - Wise balance replay failed (#{e.class}); funding and split marks are unchanged",
        operation: "balance_replay",
        error_class: e.class.name
      )
      payloads
    end

    # A balance is replayed only when its rows can hold everything that moved
    # it: a full-history import whose fetches all succeeded and reached back
    # to the balance's creation, an open STANDARD balance not invested (its
    # holdings move without rows), without statement coverage (statement rows
    # are not replayed), no jar in its currency (jar moves and interest), no
    # other open balance in its currency, no stored credit for a transfer
    # Sure does not have (it may be a transfer Wise lists late), and Wise
    # held the same amount before and after the fetch.
    def balances_to_replay(payloads)
      return [] unless full_history? && @fetch_failures.zero? && @live_amounts.any?
      return [] unless @fetched_windows.key?(:transfers) && @fetched_windows.key?(:activities)
      # A deferred credit is in no payload yet.
      return [] if @deferred_activity_times.any?

      coverage = coverage_after_fetch
      jar_currencies = WiseAccount.where(wise_item_id: wise_item.id).select(&:jar?).map(&:currency).to_set
      open_standard = payloads.keys.reject { |wise_account| wise_account.jar? || wise_account.closed? }
      shared_currencies = open_standard.group_by(&:currency).select { |_currency, accounts| accounts.size > 1 }.keys

      open_standard.filter_map do |wise_account|
        live = @live_amounts[wise_account.balance_id.to_s]
        next unless live && replayable_balance?(wise_account, payloads[wise_account], coverage)
        next if jar_currencies.include?(wise_account.currency) || shared_currencies.include?(wise_account.currency)

        WiseItem::BalanceReplay::Balance.new(key: wise_account.id, currency: wise_account.currency, live: live,
                                             rows: payloads[wise_account])
      end
    end

    def replayable_balance?(wise_account, payload, coverage)
      snapshot = wise_account.raw_payload.is_a?(Hash) ? wise_account.raw_payload : {}
      created_at = parse_utc(snapshot["creationTime"])
      return false unless created_at && snapshot["investmentState"] == "NOT_INVESTED"
      return false if @statement_covered_account_ids.include?(wise_account.id)

      covered = %w[transfers activities].all? do |source|
        from = parse_utc(coverage.dig(source, "from"))
        from && from <= created_at
      end
      covered && payload.none? { |row| unmatched_transfer_activity?(row) }
    end

    # Activities of transfers are stored only for transfers Sure does not
    # have (#transfer_activity_route).
    def unmatched_transfer_activity?(row)
      WiseActivity::Processor.activity_row?(row) &&
        WiseActivity::Processor::TRANSFER_TYPES.include?(row["type"].to_s) &&
        row["resource"].is_a?(Hash) && row["resource"]["type"] == "TRANSFER"
    end

    def apply_balance_replay(payloads, result)
      payloads.to_h do |wise_account, payload|
        externals = result.funding[wise_account.id]
        rows = payload.map do |row|
          if externals && transfer_row?(row)
            external = externals.include?(row["id"].to_s)
            with_annotations(row, "wise_funding" => (WiseItem::BalanceReplay::EXTERNAL_FUNDING if external))
          elsif WiseActivity::Processor.activity_row?(row) && (annotations = result.split_annotations[row["id"].to_s])
            with_annotations(row, annotations)
          else
            row
          end
        end
        [ wise_account, rows ]
      end
    end

    # Whether an activity the balance stores has other split marks than its
    # stored copy (one stored for the first time with none has none).
    def split_marks_changed?(wise_account, payload)
      keys = %w[wise_split_parts wise_split_estimated]
      stored = Array(wise_account.raw_transactions_payload).select { |row| WiseActivity::Processor.activity_row?(row) }.index_by { |row| row["id"] }
      payload.any? { |row| WiseActivity::Processor.activity_row?(row) && row.slice(*keys) != stored[row["id"]].to_h.slice(*keys) }
    end

    # Replaces the given marks on a row; a nil value removes the mark.
    def with_annotations(row, annotations)
      row.except(*annotations.keys).merge(annotations.compact)
    end

    # Tells support, per balance, why a replay did not reconcile (its marks
    # stay as they were) or why one that did keeps its funding marks, and
    # once when the marks changed: which transfers are now externally
    # funded and how many split parts no rate bounded.
    def report_balance_replay(result, before, after)
      accounts = before.keys.index_by(&:id)
      result.outcomes.each do |outcome|
        next if outcome.success? && outcome.funding_withheld.nil?

        message =
          if outcome.success?
            "replays to its live amount, but part of it went into a split payment share Sure cannot confirm " \
              "(#{outcome.funding_withheld}); its funding marks stay as they were"
          else
            "does not replay to its live amount (#{outcome.reason}); its funding and split marks stay as they were"
          end
        capture_debug_log(
          category: "provider_sync",
          level: "warn",
          message: "WiseItem::Importer - The Wise #{outcome.currency} balance #{message}",
          wise_account: accounts[outcome.key],
          operation: "balance_replay",
          reason: (outcome.reason || outcome.funding_withheld).to_s,
          **outcome.counts
        )
      end

      changed = before.sum do |wise_account, rows|
        rows.zip(after[wise_account]).count do |old_row, new_row|
          old_row.slice(*WiseItem::BalanceReplay::ANNOTATION_KEYS) != new_row.slice(*WiseItem::BalanceReplay::ANNOTATION_KEYS)
        end
      end
      return if changed.zero?

      unbounded = result.outcomes.select(&:success?).sum { |outcome| outcome.notes.fetch(:unbounded_part_count, 0) }
      external_ids = result.funding.values.flat_map(&:to_a).sort
      capture_debug_log(
        category: "provider_sync",
        level: "info",
        message: "WiseItem::Importer - The Wise balance replay changed the funding or split marks of #{changed} rows",
        operation: "balance_replay",
        changed_row_count: changed,
        external_transfer_count: external_ids.size,
        external_transfer_ids: external_ids.first(MAX_LOGGED_TRANSFER_IDS).presence,
        unbounded_part_count: unbounded.nonzero?
      )
    end

    # The replay needs what Wise holds once the transfers and activities are
    # fetched, so the balances are read again: { balance id => amount +
    # reservedAmount (card holds are not booked) } for each balance that did
    # not move since the first read. One that did (a card payment settling
    # in between) cannot be told apart from a missing row, so it waits.
    def fetch_live_amounts(first_read)
      before = balance_amounts(first_read)
      balance_amounts(Provider::Wise.with_retries { wise_provider.get_balances(wise_item.profile_id) }).filter_map do |balance_id, amounts|
        [ balance_id, amounts.sum ] if before[balance_id] == amounts
      end.to_h
    rescue => e
      trace_wise_fetch(operation: "balances", status: "failed", level: "warn", error: e, purpose: "balance_replay")
      {}
    end

    def balance_amounts(balances)
      Array(balances).each_with_object({}) do |balance, amounts|
        next unless balance.is_a?(Hash) && balance["id"].present?

        amounts[balance["id"].to_s] = [ balance.dig("amount", "value").to_d, balance.dig("reservedAmount", "value").to_d ]
      end
    end

    # Only a full-history import whose fetches all succeeded replays, and
    # only balances Wise describes well enough (#replayable_balance?); the
    # second balance read is skipped otherwise.
    def balance_replay_wanted?(first_read)
      return false unless full_history? && @fetch_failures.zero?

      Array(first_read).any? do |balance|
        balance.is_a?(Hash) && balance["investmentState"] == "NOT_INVESTED" && balance["creationTime"].present?
      end
    end

    # A transfer goes to the balance it reaches (WiseEntry::Processor
    # .balance_route, the rule the balance books it by), created at a time
    # the balance takes rows (#takes_row?). Wise does not say whether a
    # balance paid for a pay-in ("send to myself"), so none is debited for it
    # (see #report_transfer_notes).
    def transfer_for_account?(transfer, wise_account)
      route = WiseEntry::Processor.balance_route(transfer, wise_account, own_recipient_ids: own_recipient_ids,
                                                                        recipient_owners: balance_recipient_owners)
      # The balance's own account details name it, whatever else shares its currency.
      route.present? && takes_row?(wise_account, by_currency: route == :currency, debit: !pay_in?(transfer)) { transfer_created_at(transfer) }
    end

    # Whether a balance takes a row created at the time the block returns
    # (read only when the balance has a window, see #routing_windows).
    # by_currency: false when the row names the balance itself, so only its
    # closure limits it. debit: the row takes money from the balance.
    def takes_row?(wise_account, by_currency: true, debit: false)
      window = routing_windows[wise_account.id] || {}
      window = window.slice(:through) unless by_currency
      return true if window.values.none?

      time = yield
      return false unless time

      from = (window[:debits_from] if debit) || window[:from]
      before = (window[:credits_before] unless debit) || window[:before]
      (from.nil? || time >= from) && (before.nil? || time < before) && (window[:through].nil? || time <= window[:through])
    end

    # The times whose rows each balance takes, { wise_account id => { from:,
    # before:, through:, debits_from:, credits_before: } }. A closed balance
    # takes the rows created until Sure found it closed (`through`), and a jar
    # those from a day before Wise opened it (`from`). Wise keeps one STANDARD
    # balance per currency, so two of them mean the currency was closed and
    # opened again under a new balance id: the older one takes the rows from
    # before Wise opened the newer one (`before`), the newer one those after,
    # so no movement books on both. In the day before (a pay-in can be dated
    # before the balance it reached existed), money that came in went to the
    # newer one (`from`, `credits_before`) and money that left, such as the
    # conversion that emptied the older one, left the older one, as the
    # newer held nothing yet (`debits_from`). Only balances Wise dated can be
    # ordered.
    def routing_windows
      @routing_windows ||= begin
        accounts = wise_item.wise_accounts.to_a
        windows = accounts.to_h do |wise_account|
          opened = wise_account.creation_time - 1.day if wise_account.jar? && wise_account.creation_time
          [ wise_account.id, { from: opened, before: nil, through: wise_account.closed_at } ]
        end
        accounts.reject(&:jar?).select(&:creation_time).group_by(&:currency).each_value do |standard|
          standard.sort_by(&:creation_time).each_cons(2) do |older, newer|
            margin = newer.creation_time - 1.day
            windows[older.id].merge!(before: newer.creation_time, credits_before: margin)
            windows[newer.id].merge!(from: margin, debits_from: newer.creation_time)
          end
        end
        windows
      end
    end

    def own_recipient_ids
      @own_recipient_ids ||= wise_item.own_recipient_ids
    end

    def balance_recipient_owners
      @balance_recipient_owners ||= wise_item.balance_recipient_owners
    end

    # Activities whose resource is a transfer, by transfer id.
    def transfer_activities_by_id(activities)
      Array(activities).each_with_object({}) do |activity, index|
        resource = activity["resource"] if activity.is_a?(Hash)
        next unless resource.is_a?(Hash) && resource["type"] == "TRANSFER" && resource["id"].present?

        (index[resource["id"].to_s] ||= []) << activity
      end
    end

    # Attaches the activity Wise shows for a transfer: it carries the gross
    # debit (sourceValue excludes the fee), the direction markup and the
    # counterparty's name. Several activities can share a transfer's id (a
    # refund credit, a send to the profile's own account details): the one
    # created closest to the transfer whose markup fits its direction becomes
    # "wise_activity" (with no recipient known, the closest one decides the
    # direction), and a credit on a payout becomes "wise_refund_activity": the
    # latest one Wise did not cancel, else the latest cancelled one, whose
    # snapshot then replaces one an earlier sync took while it was in
    # progress (WiseEntry::Processor.refund books no cancelled credit). A
    # transfer this sync saw no activity for keeps its stored ones
    # (#merge_transaction_payloads).
    def enrich_transfer(transfer, transfer_activities)
      candidates = transfer_activities[transfer["id"].to_s]
      return transfer if candidates.blank?

      direction = (WiseEntry::Processor.direction(transfer, own_recipient_ids: own_recipient_ids) if own_recipient_ids.any?)
      fitting = candidates.select { |activity| direction.nil? || credit_activity?(activity) == (direction == :incoming) }
      activity = closest_to_created(transfer, fitting)
      direction ||= activity && credit_activity?(activity) ? :incoming : :outgoing
      if direction == :outgoing
        credits = candidates.select { |candidate| credit_activity?(candidate) }
        refund = latest_created(credits.reject { |credit| credit["status"] == "CANCELLED" }) || latest_created(credits)
      end

      enrichment = { "wise_activity" => activity, "wise_refund_activity" => refund }.compact
      return transfer if enrichment.empty?

      transfer.merge(enrichment.transform_values { |snapshot| WiseEntry::Processor.activity_snapshot(snapshot) })
    end

    def credit_activity?(activity)
      WiseActivity::Processor.direction(activity) == :credit
    end

    def closest_to_created(transfer, activities)
      created = transfer_created_at(transfer)
      activities.min_by do |activity|
        time = activity_created_at(activity)
        [ created && time ? (time - created).abs : Float::INFINITY, time&.to_f || Float::INFINITY, activity["id"].to_s ]
      end
    end

    def latest_created(activities)
      activities.max_by { |activity| [ activity_created_at(activity)&.to_f || -Float::INFINITY, activity["id"].to_s ] }
    end

    # Tells support about transfers Sure cannot book in full, once per change
    # (a new transfer, a new status, a new enrichment): a status Sure does not
    # book (Wise's "unknown" or an undocumented one), several activities
    # sharing a transfer's id, and pay-ins whose activity shows a debit or
    # another currency. Another balance may have paid such a pay-in ("send to
    # myself"), but Wise does not say, so Sure books only the credit.
    def report_transfer_notes(transfers, stored_transfers, transfer_activities)
      unknown_status = []
      shared = []
      balance_funded = []

      transfers.each do |transfer|
        id = transfer["id"].to_s
        stored = stored_transfers[id]
        if WiseEntry::Processor.unknown_status?(transfer) && (stored.nil? || stored["status"] != transfer["status"])
          unknown_status << transfer
        end

        candidates = transfer_activities[id]
        next if candidates.blank? || (stored && enrichment_ids(stored) == enrichment_ids(transfer))

        shared << transfer if candidates.size > 1
        balance_funded << transfer if pay_in?(transfer) && possibly_balance_funded?(transfer, candidates)
      end

      log_transfer_note(unknown_status, level: "warn",
                                        message: "have a status Sure does not book; they stay unbooked until Wise moves them on",
                                        statuses: unknown_status.map { |transfer| transfer["status"].to_s }.uniq)
      log_transfer_note(shared, level: "info",
                                message: "share their id with several activities; the one created closest to the transfer that fits its direction is used",
                                activity_counts: shared.first(MAX_LOGGED_TRANSFER_IDS).map { |transfer| transfer_activities[transfer["id"].to_s].size })
      log_transfer_note(balance_funded, level: "warn",
                                        message: "into the profile's own account details show a debit or another currency in their activity; " \
                                                 "if another balance paid them (\"send to myself\"), that debit is not booked")
    end

    def enrichment_ids(transfer)
      transfer.values_at(*ENRICHMENT_KEYS).map { |activity| activity["id"] if activity.is_a?(Hash) }
    end

    def pay_in?(transfer)
      WiseEntry::Processor.direction(transfer, own_recipient_ids: own_recipient_ids) == :incoming
    end

    # A pay-in's activities normally only credit its target currency.
    def possibly_balance_funded?(transfer, activities)
      target = transfer["targetCurrency"].presence
      activities.any? do |activity|
        currencies = %w[primaryAmount secondaryAmount].flat_map do |key|
          WiseActivity::Processor.parse_amount(activity[key])[:currencies]
        end
        !credit_activity?(activity) || (target.present? && (currencies - [ target ]).any?)
      end
    end

    def log_transfer_note(transfers, level:, message:, **metadata)
      return if transfers.empty?

      capture_debug_log(
        category: "provider_sync",
        level: level,
        message: "WiseItem::Importer - #{transfers.size} Wise transfers #{message}",
        operation: "transfers",
        transfer_count: transfers.size,
        transfer_ids: transfers.first(MAX_LOGGED_TRANSFER_IDS).map { |transfer| transfer["id"] },
        **metadata
      )
    end

    # A re-fetched row replaces its stored copy but keeps what Sure attached
    # to that copy (STICKY_ROW_KEYS) unless it brings its own.
    def merge_transaction_payloads(transactions)
      transactions.each_with_object({}) do |transaction, merged|
        key = payload_key(transaction)
        merged[key] = with_sticky_keys(transaction, merged[key])
      end.values
    end

    # What tells the copies of one row in a payload apart from other rows.
    def payload_key(row)
      if row["wise_statement"].present?
        statement_key(row)
      elsif WiseActivity::Processor.activity_row?(row)
        [ "activity", row["id"] || row.to_json ]
      else
        [ "transfer", row["id"] || row.to_json ]
      end
    end

    def with_sticky_keys(row, stored)
      kept = stored.is_a?(Hash) ? stored.slice(*STICKY_ROW_KEYS).except(*row.keys) : {}
      kept.empty? ? row : row.merge(kept)
    end

    # Wise reuses a transfer's reference on its refund, so a statement row is
    # told apart by its reference, type (DEBIT/CREDIT), time and amount.
    def statement_key(row)
      reference = row["referenceNumber"].presence
      return [ "statement", row["id"] || row.except(*WiseItem::StatementMigration::MARKER_KEYS).to_json ] unless reference

      posted_at = WiseStatement::Processor.posted_at(row)
      [ "statement", reference, row["type"].to_s, posted_at&.iso8601(3) || row["date"].to_s, row.dig("amount", "value").to_d.to_s("F") ]
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

    # Whether the given balance stores an activity (see #activity_route).
    # Activities are fetched profile-wide, so without this filter every
    # balance would show every activity.
    # - Conversions (INTERBALANCE, AUTO_CONVERSION): the jar of a jar move
    #   (#jar_move) and the STANDARD balance on its other side; a STANDARD
    #   balance on either side of a conversion between two balances.
    # - Interest, cashback and fees on holdings: the jar or invested balance
    #   in their currency, else the balance in it (#holding_balance).
    # - Single-leg activities: each open STANDARD balance that paid or
    #   received it (several for a split payment), unless statements cover
    #   that balance, whose statement rows then carry the movement.
    # Activities reach a closed balance only if created before it closed, a
    # jar only once it was opened, and in a currency Wise closed and opened
    # again only the balance of their time (#takes_row?).
    # stored: re-routes a row an earlier sync stored on this balance.
    # ignore_statements: as if statements did not cover the balance, for
    # stored rows its statement rows take over (#hand_over_to_statements).
    def activity_for_account?(activity, wise_account, stored: false, ignore_statements: false)
      case activity_route(activity, stored: stored)
      when :conversion
        routed =
          if wise_account.jar?
            move = jar_move(activity)
            # While several jars fit, each keeps the copy an earlier sync
            # stored on it, so the clean-up deletes none of their entries.
            move[:jar]&.id == wise_account.id || (stored && Array(move[:candidates]).include?(wise_account))
          else
            standard_interbalance_for_account?(activity, wise_account)
          end
        routed && takes_row?(wise_account, debit: leaves_balance?(activity, wise_account)) { activity_created_at(activity) }
      when :holding
        holding_balance(activity)[:balance]&.id == wise_account.id &&
          (wise_account.jar? || ignore_statements || !statement_covered?(wise_account) { activity_created_at(activity) })
      when :single_leg
        single_leg_for_account?(activity, wise_account, ignore_statements: ignore_statements)
      else
        false
      end
    end

    # The jar a move between a balance and a jar belongs to, decided once
    # per sync and activity: { jar: } or { state: } when there is none:
    #   :conversion    a conversion between two balances, no jar named
    #   :unidentified  a move in one currency whose jar Sure cannot tell
    #   :ambiguous     several jars fit (`candidates:`)
    # A move first routed to a jar stays with it (#routing_decision). Else
    # the title decides: a jar in the currency of the move's jar side
    # (#jar_currency) that Wise has called by the name it gives
    # (WiseAccount#known_names); in one currency, a title naming that
    # currency (the balance) is a withdrawal from the only jar in it. Of
    # several that fit, the one an earlier sync stored the move on keeps it.
    def jar_move(activity)
      (@jar_moves ||= {})[decision_key(activity)] ||= begin
        time = activity_created_at(activity)
        currency = jar_currency(activity)
        decided = routing_decision(activity, time)
        if decided&.jar? && decided.currency == currency
          { jar: decided }
        else
          named = WiseActivity::Processor.named_balance(activity)
          candidates, none =
            if WiseActivity::Processor.conversion_currencies(activity) then [ jars_named(named, [ currency ], time), :conversion ]
            elsif named.present? && named.casecmp?(currency.to_s) then [ jars_in(currency, time), :unidentified ]
            else [ jars_named(named, [ currency ].compact, time), :unidentified ]
            end
          pick_jar(activity, candidates, none: none)
        end
      end
    end

    # The one jar that fits; of several, the one an earlier sync stored the
    # move on, as no title tells them apart (several or none of them hold
    # it: :ambiguous, see #activity_for_account?).
    def pick_jar(activity, candidates, none:)
      return { state: none } if candidates.empty?
      return { jar: candidates.first } if candidates.one?

      holders = candidates.select { |jar| stored_on?(jar, activity) }
      holders.one? ? { jar: holders.first } : { state: :ambiguous, candidates: candidates }
    end

    # The currency of a jar move's jar side. Between two currencies the
    # title points at it: a deposit ("To <strong>Holiday</strong>") credits
    # the jar in the primary currency, money taken "From" a jar is debited
    # from it in the secondary one (WiseActivity::Processor.jar_deposit?).
    # So a jar of that name in the other currency is never it.
    def jar_currency(activity)
      conversion = WiseActivity::Processor.conversion_currencies(activity)
      return move_currencies(activity).first unless conversion

      WiseActivity::Processor.jar_deposit?(activity) ? conversion[:target] : conversion[:source]
    end

    # Whether the activity is in the balance's payload as an earlier sync
    # stored it.
    def stored_on?(wise_account, activity)
      key = decision_key(activity)
      Array(wise_account.raw_transactions_payload).any? { |row| WiseActivity::Processor.activity_row?(row) && decision_key(row) == key }
    end

    # The balance interest, cashback or a fee on holdings goes to, once per
    # sync and activity: { balance: } or { state: } when there is none
    # (:ambiguous, :unrouted). A row first routed to a balance stays with it
    # (#routing_decision). Else the jar or invested balance in its currency,
    # the jar the title names when there are several, and without one the
    # balance in its currency (`fallback: true`).
    def holding_balance(activity)
      (@holding_balances ||= {})[decision_key(activity)] ||= begin
        time = activity_created_at(activity)
        currency = WiseActivity::Processor.balance_amount(activity)&.dig(:currency)
        debit = WiseActivity::Processor.direction(activity) == :debit
        decided = routing_decision(activity, time)
        if decided && decided.currency == currency
          { balance: decided }
        else
          holders = jars_in(currency, time) + standard_balances_in(currency, time, debit: debit).select { |wise_account| invested?(wise_account) }
          if holders.size > 1
            named = jars_named(WiseActivity::Processor.named_balance(activity), [ currency ], time) & holders
            named.one? ? { balance: named.first } : { state: :ambiguous }
          elsif holders.one?
            { balance: holders.first }
          else
            standard = standard_balances_in(currency, time, debit: debit)
            if standard.one? then { balance: standard.first, fallback: true }
            elsif standard.empty? then { state: :unrouted }
            else { state: :ambiguous }
            end
          end
        end
      end
    end

    # The balance a stored copy of the row says it was first routed to
    # (ROUTING_DECISION_KEY), as long as that balance still takes it.
    def routing_decision(activity, time)
      balance_id = activity[ROUTING_DECISION_KEY].presence || routing_decisions[decision_key(activity)]
      decided = accounts_by_balance_id[balance_id.to_s] if balance_id.present?
      decided if decided && takes_row?(decided, debit: WiseActivity::Processor.direction(activity) == :debit) { time }
    end

    # { activity id => balance id } from every stored copy that carries one.
    def routing_decisions
      @routing_decisions ||= wise_item.wise_accounts.each_with_object({}) do |wise_account, decisions|
        Array(wise_account.raw_transactions_payload).each do |row|
          next unless WiseActivity::Processor.activity_row?(row) && row[ROUTING_DECISION_KEY].present?

          decisions[decision_key(row)] ||= row[ROUTING_DECISION_KEY].to_s
        end
      end
    end

    # Writes where a jar move or a row of interest or fees was routed onto
    # the copy about to be stored, and removes a stale mark. Other rows are
    # left as they are. Interest that fell back to the balance in its
    # currency while the jar list failed is not marked, so the jar it may
    # belong to takes it once listed.
    def with_routing_decision(row)
      return row unless WiseActivity::Processor.activity_row?(row)

      type = row["type"].to_s
      decided =
        if WiseActivity::Processor::TWO_LEG_TYPES.include?(type) then jar_move(row)[:jar]
        elsif WiseActivity::Processor::HOLDING_TYPES.include?(type)
          route = holding_balance(row)
          route[:balance] unless route[:fallback] && @balance_list_failed
        else return row
        end
      decided ? row.merge(ROUTING_DECISION_KEY => decided.balance_id.to_s) : row.except(ROUTING_DECISION_KEY)
    end

    def decision_key(activity)
      activity["id"].presence&.to_s || activity.to_json
    end

    # The currencies a move between two balances is in: the credited
    # (primary) one first.
    def move_currencies(activity)
      %w[primaryAmount secondaryAmount].filter_map { |key| WiseActivity::Processor.parse_money(activity[key]).last }.uniq
    end

    def jars_in(currency, time)
      jars.select { |jar| jar.currency == currency && takes_row?(jar) { time } }
    end

    # Jars in one of the currencies that Wise calls by this name now or, if
    # none, that Wise called by it before (WiseAccount#known_names): a title
    # names a jar as it was called then, but a jar opened under a name
    # another jar had before takes the moves naming it. A bare currency
    # code names that currency's STANDARD balance ("To <strong>EUR</strong>"),
    # not a jar called like it.
    def jars_named(named, currencies, time)
      return [] if named.blank? || standard_currencies.include?(named.upcase)

      named_jars = jars.select do |jar|
        currencies.include?(jar.currency) && jar.known_names.any? { |name| name.casecmp?(named) } && takes_row?(jar) { time }
      end
      named_jars.select { |jar| jar.current_name&.casecmp?(named) }.presence || named_jars
    end

    def standard_balances_in(currency, time, debit: false)
      wise_item.wise_accounts.reject(&:jar?).select { |wise_account| wise_account.currency == currency && takes_row?(wise_account, debit: debit) { time } }
    end

    def invested?(wise_account)
      INVESTED_STATES.include?(wise_account.raw_payload["investmentState"]) if wise_account.raw_payload.is_a?(Hash)
    end

    def jars
      @jars ||= wise_item.wise_accounts.select(&:jar?)
    end

    def accounts_by_balance_id
      @accounts_by_balance_id ||= wise_item.wise_accounts.index_by { |wise_account| wise_account.balance_id.to_s }
    end

    # Every STANDARD balance's currency, closed ones included.
    def standard_currencies
      @standard_currencies ||= wise_item.wise_accounts.reject(&:jar?).map(&:currency).to_set
    end

    # How an activity reaches the balances:
    #   :conversion  both sides of a move between the profile's own balances
    #   :holding     interest, cashback and fees on holdings
    #   :single_leg  the balance(s) that paid or received it
    #   :transfer    none: it enriches a transfer Sure has (#enrich_transfer)
    #   :deferred    none yet: a credit for a transfer this sync could not
    #                look for, as its transfer list did not arrive
    #   :unbooked    none: a type Sure does not book (wrapper types whose
    #                money moves as /v1/transfers transfers, card checks,
    #                types not seen yet), or a debit for an unknown transfer
    def activity_route(activity, stored: false)
      type = activity["type"].to_s
      if WiseActivity::Processor::TWO_LEG_TYPES.include?(type) then :conversion
      elsif WiseActivity::Processor::HOLDING_TYPES.include?(type) then :holding
      elsif WiseActivity::Processor::SINGLE_LEG_TYPES.include?(type) then :single_leg
      elsif WiseActivity::Processor::TRANSFER_TYPES.include?(type) then transfer_activity_route(activity, stored: stored)
      else :unbooked
      end
    end

    # The activity of a transfer Sure has only enriches it. A credit for one
    # it does not have (paid into the account details from a bank or another
    # Wise profile, which /v1/transfers does not list) is booked, but a new
    # one only when this sync's transfer list would show that transfer: not
    # when the list did not arrive, nor for an activity created after the
    # list was read (its transfer may be younger than the list). So a
    # transfer that is merely late is not booked twice. A row stored that
    # way stays.
    def transfer_activity_route(activity, stored:)
      resource = activity["resource"].is_a?(Hash) ? activity["resource"] : {}
      of_transfer = resource["type"] == "TRANSFER"
      return :transfer if of_transfer && @known_transfer_ids.include?(resource["id"].to_s)
      return :unbooked unless WiseActivity::Processor.direction(activity) == :credit
      return :deferred if of_transfer && !stored && !transfer_list_covers?(activity)

      :single_leg
    end

    # Whether this sync's transfer list arrived and was read after the
    # activity was created (#transfer_activity_route).
    def transfer_list_covers?(activity)
      listed = @fetched_windows[:transfers]
      return false unless listed

      created_at = activity_created_at(activity)
      created_at.nil? || created_at < listed[:through]
    end

    def single_leg_for_account?(activity, wise_account, ignore_statements: false)
      return false if wise_account.jar?
      return false if !ignore_statements && statement_covered?(wise_account) { activity_created_at(activity) }

      funding = WiseActivity::Processor.balance_amount(activity)
      funding.present? && funding[:currencies].include?(wise_account.currency) &&
        takes_row?(wise_account, debit: funding[:direction] == :debit) { activity_created_at(activity) }
    end

    # Whether a balance's leg of a move between two balances takes money from
    # it: a conversion's source, a balance's move into a jar, a jar's move out.
    def leaves_balance?(activity, wise_account)
      conversion = WiseActivity::Processor.conversion_currencies(activity)
      return conversion[:source] == wise_account.currency if conversion

      wise_account.jar? != WiseActivity::Processor.jar_deposit?(activity)
    end

    # Transfers Sure has: listed or read this sync, or stored on any balance.
    def known_transfer_ids(transfers)
      stored = wise_item.wise_accounts.flat_map do |wise_account|
        Array(wise_account.raw_transactions_payload).select { |row| transfer_row?(row) }
      end
      (transfers + stored).filter_map { |transfer| transfer["id"].presence&.to_s }.to_set
    end

    # Balances whose statements carry their card payments and other
    # single-leg movements: those that hold statement rows, and those whose
    # statements this sync returned rows for.
    def statement_covered_account_ids(statements)
      wise_item.wise_accounts.filter_map do |wise_account|
        stored = Array(wise_account.raw_transactions_payload).any? { |row| row["wise_statement"].present? }
        wise_account.id if stored || Array(statements[wise_account.id]).any?
      end.to_set
    end

    # Whether a balance's statements carry its movement of the time the block
    # returns (see #statement_covered_account_ids). Once Wise refuses them,
    # they carry what happened until they last reached (#statement_cutoffs),
    # and the balance takes what happened after from transfers and
    # activities, which hand it over to the statement rows when they work
    # again (WiseItem::StatementMigration).
    def statement_covered?(wise_account)
      return false unless @statement_covered_account_ids.include?(wise_account.id)

      cutoff = @statement_cutoffs[wise_account.id]
      return true unless cutoff

      time = yield
      time.nil? || time <= cutoff
    end

    # { wise_account id => time } for each balance whose statements Wise
    # refused this sync: the end of their coverage, else its latest statement
    # row.
    def statement_cutoffs
      wise_item.wise_accounts.select { |wise_account| @statements_refused_accounts.include?(wise_account.id) }.to_h do |wise_account|
        statement_rows = Array(wise_account.raw_transactions_payload).select { |row| row["wise_statement"].present? }
        latest = statement_rows.filter_map { |row| WiseStatement::Processor.posted_at(row) }.max
        [ wise_account.id, wise_account.statements_coverage&.dig(:through) || latest ]
      end.compact
    end

    def open_standard_currencies
      @open_standard_currencies ||= wise_item.wise_accounts.reject { |wise_account| wise_account.jar? || wise_account.closed? }
                                                          .map(&:currency).to_set
    end

    # Tells support, once per sync, about this sync's activities that book on
    # no balance or that Sure books on its own judgement: types it does not
    # book (counted per type), credits for transfers it does not have
    # (booked, or deferred while the transfer list failed), activities in a
    # currency no balance holds, split payments in a currency none of their
    # balances is in (booked in full on the first one until the balance
    # replay finds the parts), jar moves whose jar the title does not tell
    # (#jar_move: booked on no jar) and interest or fees several jars or
    # invested balances could hold (#holding_balance: booked nowhere).
    # Counts and currencies only.
    def report_activity_routing(activities)
      unbooked = Hash.new(0)
      unmatched = 0
      deferred = 0
      unrouted = 0
      unrouted_currencies = Set.new
      foreign_splits = 0
      unclear_jar_moves = Hash.new(0)
      ambiguous_holdings = 0

      activities.each do |activity|
        case activity_route(activity)
        when :unbooked
          unbooked[activity["type"].to_s.presence || "unknown"] += 1
        when :deferred
          deferred += 1
        when :conversion
          state = jar_move(activity)[:state]
          unclear_jar_moves[state] += 1 if %i[ambiguous unidentified].include?(state)
        when :holding
          case holding_balance(activity)[:state]
          when :ambiguous
            ambiguous_holdings += 1
          when :unrouted
            unrouted += 1
            unrouted_currencies.merge(Array(WiseActivity::Processor.balance_amount(activity)&.dig(:currencies)))
          end
        when :single_leg
          unmatched += 1 if WiseActivity::Processor::TRANSFER_TYPES.include?(activity["type"].to_s)
          funding = WiseActivity::Processor.balance_amount(activity)
          currencies = Array(funding&.dig(:currencies))
          foreign_splits += 1 if funding&.dig(:split) && currencies.exclude?(funding[:currency])
          next if currencies.any? { |currency| open_standard_currencies.include?(currency) }

          unrouted += 1
          unrouted_currencies.merge(currencies)
        end
      end
      unclear = unrouted + foreign_splits + unclear_jar_moves.values.sum + ambiguous_holdings
      return if unbooked.empty? && (unmatched + deferred + unclear).zero?

      capture_debug_log(
        category: "provider_sync",
        level: unclear.positive? ? "warn" : "info",
        message: "WiseItem::Importer - Wise activities this sync that book on no balance or on one side only, or that " \
                 "are booked as payments into the account for transfers Sure does not have",
        operation: "activity_routing",
        unbooked_type_counts: unbooked.presence,
        unmatched_transfer_count: unmatched.nonzero?,
        deferred_transfer_count: deferred.nonzero?,
        unrouted_count: unrouted.nonzero?,
        unrouted_currencies: unrouted_currencies.to_a.presence,
        foreign_split_count: foreign_splits.nonzero?,
        ambiguous_jar_move_count: unclear_jar_moves[:ambiguous].nonzero?,
        unidentified_jar_move_count: unclear_jar_moves[:unidentified].nonzero?,
        ambiguous_holding_count: ambiguous_holdings.nonzero?
      )
    end

    # A STANDARD balance takes its side of a conversion, the source or the
    # target currency, unless a jar holds that side: a jar move between two
    # currencies, whose jar side is in the currency its title points at
    # (#jar_currency), also while it is unclear which of several jars it
    # was. It always takes its side of a jar move in its own currency, also
    # when the jar is unknown.
    def standard_interbalance_for_account?(activity, wise_account)
      conversion = WiseActivity::Processor.conversion_currencies(activity)

      if conversion
        jar_side = jar_currency(activity) unless jar_move(activity)[:state] == :conversion
        conversion.values.include?(wise_account.currency) && wise_account.currency != jar_side
      else
        currency = WiseActivity::Processor.parse_money(activity["primaryAmount"]).last
        currency.blank? || currency == wise_account.currency
      end
    end

    def full_history?
      wise_item.import_all_history?
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
        coverage_upgraded: false,
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
