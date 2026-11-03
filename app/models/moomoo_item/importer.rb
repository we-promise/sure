class MoomooItem::Importer
  include MoomooAccount::DataHelpers

  MAX_REQUESTS_PER_SYNC = ENV.fetch("MOOMOO_MAX_REQUESTS_PER_SYNC", "250").to_i
  HISTORY_DAYS = ENV.fetch("MOOMOO_HISTORY_DAYS", "730").to_i.clamp(1, 730)
  # moomoo's fills and orders queries cover at most 90 days each.
  WINDOW = 89.days
  # The fills window is taken to filter on update time (moomoo SG fills show
  # none), so re-reading a week picks up fills moomoo has since changed or
  # cancelled.
  FILL_OVERLAP = 7.days
  CASH_LOG_OVERLAP = 3.days
  CLOSED_HISTORY_GAP = { gap_from_us: nil, gap_until_us: nil }.freeze
  CLOSED_CASH_LOG_GAP = { cash_logs_gap_from: nil, cash_logs_gap_until: nil }.freeze

  FILL_FIELDS = %w[deal_id order_id trd_side code stock_name qty price create_time updated_time status].freeze
  ORDER_FIELDS = %w[order_id code stock_name security_type currency side order_status dealt_qty dealt_avg_price create_time updated_time exchange].freeze
  CASH_LOG_FIELDS = %w[transaction_name created_time cash_change balance symbol stock_name].freeze
  CARD_NUMBER_FIELDS = %w[account_card_number univs_account_card_number].freeze
  # moomoo documents both forms; the zone is not stated.
  CASH_LOG_TIME_FORMATS = [ "%Y-%m-%d %H:%M:%S", "%m/%d/%Y %H:%M:%S" ].freeze

  # Errors about the request budget or a connection moomoo no longer accepts
  # end the import.
  FATAL_ERRORS = %i[budget_exhausted token_rejected invalid_grant invalid_client].freeze
  # After these, every later request would wait on the same rate limit or
  # token refresh, so the remaining optional work waits for the next sync.
  POSTPONING_ERRORS = %i[rate_limited token_failed].freeze

  attr_reader :moomoo_item, :provider, :budget

  def initialize(moomoo_item, provider: nil, budget: Provider::Moomoo::RequestBudget.new(MAX_REQUESTS_PER_SYNC))
    @moomoo_item = moomoo_item
    @budget = budget
    @provider = provider || moomoo_item.moomoo_provider(budget: budget)
    @now = Time.current
    @floor = @now - HISTORY_DAYS.days
    @failures = []
    @unread_accounts = {}
    @history_failures = Set.new
  end

  # Fetches in priority order under the request budget: accounts, balances and
  # positions, recent trades, recent cash logs, then the trade history and cash
  # log backfills. When the budget runs out, what was fetched is kept and the
  # next sync carries on. `failures` lists what this sync could not fetch. An
  # account whose balance and positions it couldn't refresh keeps its last
  # ones; see MoomooAccount#snapshot_stale?.
  def import
    raise Provider::Moomoo::MoomooError.new("moomoo is not connected", :not_connected) unless provider

    begin
      moomoo_item.with_access_token do |fresh_token|
        @fresh_token = fresh_token
        import_all
      end
    rescue Provider::Moomoo::MoomooError => e
      raise unless e.error_type == :budget_exhausted

      @budget_ran_out = true
    end

    log_budget_exhausted if @budget_ran_out
    moomoo_item.update!(status: :good, reauth_reason: nil)
    {
      success: true,
      requests_used: budget.used,
      backfill_pending: @budget_ran_out || moomoo_item.history_backfill_pending?,
      failures: @failures,
      rate_limited_at: @rate_limited_at
    }
  end

  private

    def import_all
      rows = request { |token| provider.get_accounts(token) }
      seen = upsert_accounts(rows)
      prune_unseen_accounts(seen)
      moomoo_item.update_columns(accounts_listed_at: @now)
      targets = moomoo_item.linkable_moomoo_accounts.primary.where(moomoo_account_id: seen).includes(:account_provider, :currency_accounts).to_a

      readable, unread = targets.partition { |moomoo_account| snapshot_imported?(moomoo_account) }
      # An unread account's history isn't fetched either. It counts toward the
      # failure limit, so an account moomoo keeps refusing, the only one shared
      # included, stops showing as importing.
      unread.each { |moomoo_account| moomoo_account.trd_markets.each { |market| note_history_failure(moomoo_account, market) } }
      # Not one account could be read: moomoo is down or refuses the whole connection.
      raise @unread_accounts.values.first if readable.empty? && unread.any?

      readable.each { |moomoo_account| import_recent_activity(moomoo_account) }
      readable.each { |moomoo_account| optional(:recent_cash_logs, moomoo_account) { import_recent_cash_logs(moomoo_account) } }
      readable.each { |moomoo_account| backfill_history(moomoo_account) }
      readable.each { |moomoo_account| optional(:cash_log_backfill, moomoo_account) { backfill_cash_logs(moomoo_account) } }
    end

    # Runs one call with a token that is valid now. A token moomoo refuses is
    # refreshed once and the call retried; a freshly issued token being refused
    # too ends the import with a reconnect request.
    def request
      token = @fresh_token.call
      yield token
    rescue Provider::Moomoo::MoomooError => e
      raise unless e.retry_with_fresh_token?

      begin
        yield @fresh_token.call(rejected: token)
      rescue Provider::Moomoo::MoomooError => retry_error
        raise unless retry_error.retry_with_fresh_token?

        raise Provider::Moomoo::MoomooError.new("moomoo refused a freshly issued access token", :token_rejected, status: retry_error.status, code: retry_error.code)
      end
    end

    # Work that may fail without failing the sync or flagging the connection:
    # the failure is reported and the stored copy kept.
    def optional(what, moomoo_account, market: nil)
      return false if @postponed

      yield
      true
    rescue Provider::Moomoo::MoomooError => e
      raise if e.error_type.in?(FATAL_ERRORS)

      if e.error_type.in?(POSTPONING_ERRORS)
        @postponed = true
        @rate_limited_at ||= Time.current if e.error_type == :rate_limited
      end
      record_failure(what, moomoo_account, e, market: market)
      false
    end

    # An account moomoo won't answer for keeps its stored copy until the next
    # sync, so it doesn't hold up the others. An error about the connection,
    # the budget or the rate limit still ends the import.
    def snapshot_imported?(moomoo_account)
      import_snapshot(moomoo_account)
      true
    rescue Provider::Moomoo::MoomooError => e
      raise if e.error_type.in?(FATAL_ERRORS + POSTPONING_ERRORS)

      @unread_accounts[moomoo_account.id] = e
      record_failure(:balances_and_positions, moomoo_account, e)
      false
    end

    def upsert_accounts(rows)
      Array(rows).filter_map do |row|
        next unless row.is_a?(Hash)

        acc_id = row["account_id"].to_s
        next if acc_id.blank?

        markets = Array(row["enable_market"]).map(&:to_i).uniq.sort
        moomoo_account = moomoo_item.moomoo_accounts.primary.find_or_initialize_by(moomoo_account_id: acc_id)
        moomoo_account.assign_attributes(
          security_firm: row["security_firm"].to_s.presence,
          acc_type: row["acc_type"].to_s.downcase.presence,
          enable_markets: markets,
          account_kind: MoomooAccount::DataHelpers.account_kind_for(markets, security_firm: row["security_firm"], acc_type: row["acc_type"]),
          account_number_mask: mask(row["account_card_number"].presence || row["univs_account_card_number"]),
          raw_account_payload: row.except(*CARD_NUMBER_FIELDS).merge("account_id" => acc_id),
          last_seen_at: @now
        )
        # Fixed at first sight; see #apply_funds.
        moomoo_account.currency ||= FIRM_HOME_CURRENCY.fetch(moomoo_account.security_firm.to_s, DEFAULT_CURRENCY)
        moomoo_account.name ||= account_display_name(moomoo_account)
        log_unsupported_kind(moomoo_account) if moomoo_account.new_record? && !moomoo_account.linkable?
        moomoo_account.save!
        acc_id
      end
    end

    # Accounts the user stopped sharing are no longer fetched. A linked one,
    # or one with a linked currency account, keeps its data in Sure; an
    # unlinked one is removed, so setup doesn't offer an account that would
    # never update.
    def prune_unseen_accounts(seen)
      moomoo_item.moomoo_accounts.primary.where.not(moomoo_account_id: seen)
        .includes(:account_provider, currency_accounts: :account_provider).find_each do |moomoo_account|
        if [ moomoo_account, *moomoo_account.currency_accounts ].any? { |row| row.account_provider.present? }
          DebugLogEntry.capture(
            category: "sync",
            level: "warn",
            message: "MoomooItem::Importer - account #{moomoo_account.account_number_mask} is no longer authorized; keeping stored data",
            source: "moomoo",
            provider_key: "moomoo",
            family: moomoo_item.family,
            account_provider: moomoo_account.account_provider,
            metadata: { moomoo_account_id: moomoo_account.id }
          )
        else
          moomoo_account.destroy!
        end
      end
    end

    # Cash is the total less the holdings, so the total and the positions stay
    # one snapshot: an answer whose total can't be used keeps the positions,
    # and the date, of the last one that could, and the account is left as it
    # is until one can (see MoomooAccount#snapshot_stale?).
    def import_snapshot(moomoo_account)
      acc_id = moomoo_account.moomoo_account_id
      funds = request { |token| provider.get_funds(token, acc_id: acc_id, currency: moomoo_account.currency) }
      positions = request { |token| provider.get_positions(token, acc_id: acc_id) }

      if apply_funds(moomoo_account, funds, positions)
        moomoo_account.update!(raw_funds_payload: funds, raw_positions_payload: positions, last_positions_sync: @now)
      else
        moomoo_account.update!(raw_funds_payload: funds)
      end
    end

    # The figures must be in the account's currency. If moomoo reports another
    # currency, an account not linked or split yet takes it; any other keeps
    # its last snapshot rather than mixing currencies. Returns whether the
    # total was applied.
    def apply_funds(moomoo_account, funds, positions)
      total = parse_decimal(funds["total_assets"])
      unless total
        funds_not_applied(moomoo_account, "warn", "funds returned no total_assets; balance not updated")
        return false
      end

      reported = parse_currency(funds["currency"])
      if reported.present? && reported != moomoo_account.currency
        if moomoo_account.current_account.present? || moomoo_account.currency_accounts.any?
          funds_not_applied(moomoo_account, "error", "funds returned #{reported}, expected #{moomoo_account.currency}; balance not updated",
                            requested: moomoo_account.currency, returned: reported)
          return false
        end

        capture_funds_problem(moomoo_account, "warn", "funds returned #{reported} instead of #{moomoo_account.currency}; the account now uses #{reported}",
                              requested: moomoo_account.currency, returned: reported)
        moomoo_account.currency = reported
      end

      moomoo_account.assign_attributes(current_balance: total, cash_balance: parse_decimal(funds["cash"]))
      apply_currency_split(moomoo_account, funds, positions)
    end

    # An account that holds more than one currency is a cash row per
    # currency, with its cash, and a stocks row per currency with positions
    # or trades, with their market value (see MoomooAccount::CurrencySplit).
    # The primary is a row of the home currency. A combined row of a
    # currency becomes its stocks row when the currency has positions or
    # trades, so its account keeps their history, and its cash row
    # otherwise. Figures that can't be divided leave an account already
    # split at its last snapshot, and one not split yet whole. Returns
    # whether the figures were applied.
    def apply_currency_split(moomoo_account, funds, positions)
      split = MoomooAccount::CurrencySplit.new(moomoo_account, funds: funds, positions: positions, date: @now.to_date)
      return true unless split.multiple_currencies?

      balances = split.balances
      rows = [ moomoo_account, *moomoo_account.currency_accounts ]
      base_name = account_display_name(moomoo_account)

      balances.each do |currency, figures|
        if split.stock_currencies.include?(currency)
          split_row(moomoo_account, rows, currency, "stocks", base_name)
            .assign_attributes(current_balance: figures[:balance] - figures[:cash], cash_balance: 0)
        end
        split_row(moomoo_account, rows, currency, "cash", base_name)
          .assign_attributes(current_balance: figures[:cash], cash_balance: figures[:cash])
      end

      rows.each { |row| row.save! unless row.equal?(moomoo_account) }
      true
    rescue MoomooAccount::CurrencySplit::Mismatch => e
      if moomoo_account.currency_accounts.any?
        moomoo_account.restore_attributes(%i[current_balance cash_balance])
        funds_not_applied(moomoo_account, "error", "#{e.message}; balances per currency not updated")
        return false
      end

      capture_funds_problem(moomoo_account, "warn", "#{e.message}; the account is not split by currency")
      true
    end

    def import_recent_activity(moomoo_account)
      moomoo_account.trd_markets.each do |market|
        optional(:today_fills, moomoo_account, market: market) do
          fills = request { |token| provider.get_today_fills(token, acc_id: moomoo_account.moomoo_account_id, trd_market: market) }
          merge_fills!(moomoo_account, market, fills[:records])
          # The trade history read next covers today too.
          log_today_fills_truncated(moomoo_account, market, fills[:reason]) if fills[:truncated]
        end

        recent = optional(:recent_trade_history, moomoo_account, market: market) do
          cursor = moomoo_account.history_cursor(market)
          newest = Provider::Moomoo.from_micros(cursor["newest_us"])
          # One call for the newest window. A first sync leaves the rest,
          # including any part of this window past the page cap, to the
          # backfill. A later sync reads from a week before the last one, and
          # what this call doesn't reach is a gap the backfill reads first, so
          # a long pause can't take every later sync's budget.
          from = newest ? [ newest - FILL_OVERLAP, @floor ].max : @floor
          read_from = fetch_fills_and_orders!(moomoo_account, market, [ @now - WINDOW, from ].max, @now)

          if newest
            moomoo_account.update_history_cursor!(
              market, newest_us: to_micros(@now), oldest_us: cursor["oldest_us"] || to_micros(from), **history_gap(cursor, from, read_from)
            )
          else
            moomoo_account.update_history_cursor!(market, newest_us: to_micros(@now), oldest_us: to_micros(read_from))
          end
        end
        note_history_failure(moomoo_account, market) unless recent
      end
    end

    # The part of a later sync's range [from, now] its recent read didn't
    # reach, joined with a gap still open. The market's history isn't complete
    # until the backfill has read it.
    def history_gap(cursor, from, read_from)
      return {} if read_from <= from

      { gap_from_us: [ cursor["gap_from_us"], to_micros(from) ].compact.min,
        gap_until_us: [ cursor["gap_until_us"], to_micros(read_from) ].compact.max,
        complete: nil }
    end

    # One window per market per round, walking back from the oldest window
    # fetched so far, so every market's history advances under the budget. A
    # gap a later sync left is read first, newest first. A market that fails
    # waits for the next sync without holding up the others.
    def backfill_history(moomoo_account)
      failed_markets = Set.new

      loop do
        progressed = false

        moomoo_account.trd_markets.each do |market|
          next if failed_markets.include?(market)

          cursor = moomoo_account.history_cursor(market)
          next if cursor["complete"]

          gap_until = Provider::Moomoo.from_micros(cursor["gap_until_us"])
          window_end = gap_until || Provider::Moomoo.from_micros(cursor["oldest_us"])
          next unless window_end

          stop = gap_until ? [ Provider::Moomoo.from_micros(cursor["gap_from_us"]), @floor ].compact.max : @floor
          if window_end <= stop
            moomoo_account.update_history_cursor!(market, **(gap_until ? CLOSED_HISTORY_GAP : { complete: true }))
            # Without the gap, the walk goes on from the oldest window.
            progressed ||= gap_until.present?
            next
          end

          unless budget.available?(2)
            @budget_ran_out = true
            return
          end

          window_start = [ window_end - WINDOW, stop ].max
          read_from = nil
          fetched = optional(:trade_history_backfill, moomoo_account, market: market) do
            read_from = fetch_fills_and_orders!(moomoo_account, market, window_start, window_end)
          end

          if fetched
            reached = if gap_until
              read_from <= stop ? CLOSED_HISTORY_GAP : { gap_until_us: to_micros(read_from) }
            else
              { oldest_us: to_micros(read_from), complete: read_from <= @floor }
            end
            moomoo_account.update_history_cursor!(market, **reached, failures: nil)
            progressed = true
          else
            failed_markets << market
            note_history_failure(moomoo_account, market)
          end
        end

        break unless progressed
      end
    end

    # Counted once per market per sync, and not when the sync was postponed.
    # Past MoomooAccount::HISTORY_FAILURE_LIMIT the market no longer counts as
    # importing, but every sync still retries it.
    def note_history_failure(moomoo_account, market)
      return if @postponed || moomoo_account.history_cursor(market)["complete"]
      return unless @history_failures.add?([ moomoo_account.id, market ])

      failures = moomoo_account.history_cursor(market)["failures"].to_i + 1
      moomoo_account.update_history_cursor!(market, failures: failures)
      log_history_stalled(moomoo_account, market) if failures == MoomooAccount::HISTORY_FAILURE_LIMIT
    end

    # Returns where the part of the window read in full starts: window_start,
    # unless fills or orders stopped short. moomoo lists both newest first, so
    # what a short result left out lies before the oldest row it returned
    # (fills by update time, or by creation time where moomoo leaves it out,
    # as moomoo SG does; orders by creation time).
    def fetch_fills_and_orders!(moomoo_account, market, window_start, window_end)
      acc_id = moomoo_account.moomoo_account_id
      range = { trd_market: market, start_us: to_micros(window_start), end_us: to_micros(window_end) }

      # Half the budget left for fills, the rest for orders: a window longer
      # than that stops short where both were read, and resumes from there.
      fills = request { |token| provider.get_fills_history(token, acc_id: acc_id, max_pages: page_allowance(share: 2), **range) }
      merge_fills!(moomoo_account, market, fills[:records])
      orders = request { |token| provider.get_orders_history(token, acc_id: acc_id, max_pages: page_allowance, **range) }
      merge_orders!(moomoo_account, orders[:records])
      return window_start unless fills[:truncated] || orders[:truncated]

      # Resuming a second after the oldest row also re-reads the rows that
      # share its time; they merge by deal_id and order_id.
      read_from = [ window_start ]
      read_from << resume_point(fills[:records], %w[updated_time create_time], window_end) if fills[:truncated]
      read_from << resume_point(orders[:records], "create_time", window_end) if orders[:truncated]
      read_from = read_from.max
      # Nothing older to resume from would repeat the same request for ever,
      # and hold up every older window behind it, so the rest is skipped;
      # unless the budget stopped it, when the next sync reads it again.
      skipped = read_from >= window_end
      budget_stop! if skipped && :request_budget.in?([ fills[:reason], orders[:reason] ])
      read_from = window_start if skipped

      log_truncated(moomoo_account, "fills and orders (#{market})", window_start, window_end, read_from, fills[:reason] || orders[:reason])
      report_skipped(:trade_history_skipped, moomoo_account, window_start, window_end, market: market) if skipped
      read_from
    end

    # The pages one call may fetch: what the budget left pays for, split
    # between the calls still to come for the window. Without it, a window
    # longer than the budget left lost every page it fetched to the budget
    # error and started over on each sync, so it never completed.
    def page_allowance(share: 1)
      [ budget.remaining / share, 1 ].max
    end

    def budget_stop!
      raise Provider::Moomoo::MoomooError.new("moomoo request budget of #{budget.limit} used up", :budget_exhausted)
    end

    # The first of `fields` a row has: moomoo SG lists fills without an
    # updated_time, so they resume from the time they were made.
    def resume_point(records, fields, fallback)
      oldest = Array(records).filter_map do |record|
        Provider::Moomoo.from_micros(Array(fields).filter_map { |field| record[field].presence }.first) if record.is_a?(Hash)
      end.min
      oldest ? oldest + 1.second : fallback
    end

    # One record per deal_id. The latest update wins, so a fill moomoo changed
    # or cancelled replaces the original.
    def merge_fills!(moomoo_account, market, records)
      incoming = Array(records).filter_map { |fill| fill.slice(*FILL_FIELDS).merge("trd_market" => market) if fill.is_a?(Hash) }
      return if incoming.empty?

      # A sync that outlives Sync::VISIBLE_FOR can overlap the next one, so
      # payloads are merged on the locked, freshly read row.
      moomoo_account.with_lock do
        merged = (Array(moomoo_account.raw_fills_payload) + incoming)
          .each_with_index
          .group_by { |fill, _index| fill["deal_id"].to_s }
          .except("")
          .map { |_deal_id, versions| versions.max_by { |fill, index| [ fill["updated_time"].to_i, index ] }.first }
          .sort_by { |fill| -fill["create_time"].to_i }
        moomoo_account.update!(raw_fills_payload: merged)
      end
    end

    # Kept for the currency and security type of each order's fills.
    def merge_orders!(moomoo_account, records)
      incoming = Array(records).each_with_object({}) do |order, orders|
        next unless order.is_a?(Hash) && order["order_id"].present?

        orders[order["order_id"].to_s] = order.slice(*ORDER_FIELDS)
      end
      return if incoming.empty?

      moomoo_account.with_lock do
        moomoo_account.update!(raw_orders_payload: moomoo_account.orders_map.merge(incoming))
      end
    end

    # Cash logs are kept with the account and imported from there (see
    # MoomooAccount::CashLogsProcessor); their rows carry no id. As for the trade history, one call reads the newest window. A first sync
    # leaves the older logs to the backfill. A later sync reads from three days
    # before the last one, and what this call doesn't reach is a gap the
    # backfill reads first. The backfill keeps its place after every call, so
    # a busy account's logs can't use up every sync's budget before the trade
    # history gets any.
    def import_recent_cash_logs(moomoo_account)
      synced_through = moomoo_account.cash_logs_synced_through
      from = synced_through ? [ synced_through - CASH_LOG_OVERLAP, @floor ].max : @floor
      read_from = merge_cash_logs!(moomoo_account, [ @now - WINDOW, from ].max, @now)

      if synced_through
        moomoo_account.update!(
          cash_logs_synced_through: @now, cash_logs_backfilled_from: moomoo_account.cash_logs_backfilled_from || from,
          **cash_log_gap(moomoo_account, from, read_from)
        )
      else
        moomoo_account.update!(cash_logs_synced_through: @now, cash_logs_backfilled_from: read_from)
      end
    end

    # As #history_gap, for the cash logs.
    def cash_log_gap(moomoo_account, from, read_from)
      return {} if read_from <= from

      { cash_logs_gap_from: [ moomoo_account.cash_logs_gap_from, from ].compact.min,
        cash_logs_gap_until: [ moomoo_account.cash_logs_gap_until, read_from ].compact.max }
    end

    # The gap a later sync left, then the logs before the first sync's, each
    # read newest first and saved after every call.
    def backfill_cash_logs(moomoo_account)
      while (window_end = moomoo_account.cash_logs_gap_until)
        stop = [ moomoo_account.cash_logs_gap_from, @floor ].compact.max
        read_from = window_end > stop ? read_cash_logs_back(moomoo_account, window_end, stop) : stop
        return unless read_from

        moomoo_account.update!(read_from <= stop ? CLOSED_CASH_LOG_GAP : { cash_logs_gap_until: read_from })
      end

      while (window_end = moomoo_account.cash_logs_backfilled_from) && window_end > @floor
        read_from = read_cash_logs_back(moomoo_account, window_end, @floor)
        return unless read_from

        moomoo_account.update!(cash_logs_backfilled_from: read_from)
      end
    end

    # One call for the window that ends at window_end and starts no earlier
    # than stop. Returns where the part read in full starts, or nil once the
    # budget is used up.
    def read_cash_logs_back(moomoo_account, window_end, stop)
      unless budget.available?
        @budget_ran_out = true
        return
      end

      merge_cash_logs!(moomoo_account, [ window_end - WINDOW, stop ].max, window_end)
    end

    # Rows have no id, so they are told apart by a digest of their content.
    # Returns where the part of the window read in full starts, as
    # #fetch_fills_and_orders! does.
    def merge_cash_logs!(moomoo_account, window_start, window_end)
      result = request do |token|
        provider.get_cash_logs(token, acc_id: moomoo_account.moomoo_account_id, begin_us: to_micros(window_start), end_us: to_micros(window_end),
                               max_pages: page_allowance)
      end

      rows = Array(result[:records]).filter_map do |row|
        next unless row.is_a?(Hash)

        row.slice(*CASH_LOG_FIELDS).merge(
          "digest" => cash_log_digest(row),
          "fetched_window" => [ to_micros(window_start), to_micros(window_end) ]
        )
      end

      if rows.any?
        moomoo_account.with_lock do
          merged = (Array(moomoo_account.raw_cash_logs_payload) + rows).uniq { |row| row["digest"] }
          moomoo_account.update!(raw_cash_logs_payload: merged)
        end
      end
      return window_start unless result[:truncated]

      # created_time carries no zone, so the rest is read from a day after the
      # oldest row; the rows read twice share a digest.
      oldest = rows.filter_map { |row| cash_log_time(row["created_time"]) }.min
      read_from = oldest ? [ oldest + 1.day, window_start ].max : window_end
      skipped = read_from >= window_end
      budget_stop! if skipped && result[:reason] == :request_budget
      read_from = window_start if skipped

      log_truncated(moomoo_account, "cash logs", window_start, window_end, read_from, result[:reason])
      report_skipped(:cash_logs_skipped, moomoo_account, window_start, window_end) if skipped
      read_from
    end

    def cash_log_digest(row)
      Digest::SHA256.hexdigest(CASH_LOG_FIELDS.map { |field| row[field].to_s }.join("\u001f"))[0, 32]
    end

    def cash_log_time(value)
      CASH_LOG_TIME_FORMATS.each do |format|
        return Time.zone.strptime(value.to_s, format)
      rescue ArgumentError
        next
      end
      nil
    end

    def to_micros(time)
      Provider::Moomoo.to_micros(time)
    end

    # Only the last four digits of a card number are kept.
    def mask(card_number)
      digits = card_number.to_s.gsub(/\s/, "")
      digits.present? ? "••#{digits.last(4)}" : nil
    end

    # The row of a split account that holds `role` for `currency`: the one
    # already there, the currency's combined row, or a new one.
    def split_row(primary, rows, currency, role, base_name)
      row = rows.find { |candidate| candidate.currency == currency && candidate.role == role } ||
        rows.find { |candidate| candidate.currency == currency && candidate.role == "combined" }
      unless row
        row = primary.currency_accounts.build(currency: currency, moomoo_item: moomoo_item)
        rows << row
      end

      unless row.equal?(primary)
        row.assign_attributes(
          moomoo_account_id: primary.moomoo_account_id,
          **primary.slice(:security_firm, :acc_type, :account_kind, :account_number_mask).symbolize_keys
        )
      end
      row.assign_attributes(role: role, name: I18n.t("moomoo_items.defaults.#{role}_account_name", name: base_name, currency: currency))
      row
    end

    def account_display_name(moomoo_account)
      firm = moomoo_account.security_firm
      firm_label = firm.present? ? I18n.t("moomoo_items.defaults.firms.#{firm}", default: firm) : nil
      I18n.t("moomoo_items.defaults.account_name", firm: firm_label, mask: moomoo_account.account_number_mask).squish
    end

    # Logged for support and returned for the sync's health.
    def record_failure(what, moomoo_account, error, market: nil)
      @failures << { what: what, market: market, account: moomoo_account.name, message: error.message }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "MoomooItem::Importer - Failed to fetch #{what.to_s.tr('_', ' ')}#{" (#{market})" if market}: #{error.message}. Keeping the stored copy.",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, error_type: error.error_type, errcode: error.code, status: error.status }.compact
      )
    end

    def funds_not_applied(moomoo_account, level, detail, **metadata)
      capture_funds_problem(moomoo_account, level, detail, **metadata)
      @failures << { what: :balances_and_positions, market: nil, account: moomoo_account.name, message: detail }
    end

    def capture_funds_problem(moomoo_account, level, detail, **metadata)
      DebugLogEntry.capture(
        category: "sync",
        level: level,
        message: "MoomooItem::Importer - account #{moomoo_account.account_number_mask}: #{detail}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: metadata.merge(moomoo_account_id: moomoo_account.id)
      )
    end

    def log_unsupported_kind(moomoo_account)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooItem::Importer - account #{moomoo_account.account_number_mask} is a #{moomoo_account.account_kind} account; not imported",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        metadata: { enable_markets: moomoo_account.enable_markets }
      )
    end

    # A window cut short with nothing to resume from is listed in the sync's
    # failures too, as part of the history won't be imported.
    def report_skipped(what, moomoo_account, window_start, window_end, market: nil)
      @failures << { what: what, market: market, account: moomoo_account.name,
                     message: "moomoo cut #{window_start.to_date}..#{window_end.to_date} short with nothing to resume from" }
    end

    def log_today_fills_truncated(moomoo_account, market, reason)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "MoomooItem::Importer - today's fills (#{market}) #{truncation_cause(reason)}; the trade history covers the rest",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, trd_market: market, reason: reason }.compact
      )
    end

    def truncation_cause(reason)
      case reason
      when :repeated_page_flag then "got a page_flag it had already sent"
      when :request_budget then "reached this sync's request budget"
      else "exceeded #{Provider::Moomoo::MAX_PAGES_PER_WINDOW} pages"
      end
    end

    def log_truncated(moomoo_account, what, window_start, window_end, read_from, reason)
      cause = truncation_cause(reason)
      outcome = read_from > window_start ? "the rest is read from #{read_from.to_date}" : "the rest of the window is skipped"

      DebugLogEntry.capture(
        category: "sync",
        # Stopping at the budget is expected; the next sync carries on.
        level: reason == :request_budget ? "info" : "warn",
        message: "MoomooItem::Importer - #{what} #{window_start.to_date}..#{window_end.to_date} #{cause}; #{outcome}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, start_us: to_micros(window_start), end_us: to_micros(window_end), reason: reason }.compact
      )
    end

    def log_history_stalled(moomoo_account, market)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "MoomooItem::Importer - trade history (#{market}) failed on #{MoomooAccount::HISTORY_FAILURE_LIMIT} syncs in a row; " \
                 "no longer shown as importing, still retried",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, trd_market: market }
      )
    end

    def log_budget_exhausted
      pending = moomoo_item.fetched_moomoo_accounts.flat_map do |moomoo_account|
        moomoo_account.trd_markets.select { |market| moomoo_account.history_pending?(market) }
      end

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooItem::Importer - request budget (#{budget.limit}) used; history continues next sync",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_item.family,
        metadata: { pending_markets: pending.uniq }
      )
    end
end
