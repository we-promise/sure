require "test_helper"

class MoomooItem::ImporterTest < ActiveSupport::TestCase
  # Answers like Provider::Moomoo, spending the budget one request per call.
  class FakeProvider
    METHODS = %i[get_accounts get_funds get_positions get_today_fills get_fills_history get_orders_history get_cash_logs].freeze

    attr_reader :calls, :handlers

    def initialize(budget)
      @budget = budget
      @calls = []
      @handlers = {}
    end

    def on(method, &handler)
      @handlers[method] = handler
    end

    def calls_to(method)
      calls.filter_map { |name, args| args if name == method }
    end

    METHODS.each do |method|
      define_method(method) do |token, **args|
        @budget.consume!
        @calls << [ method, args.merge(token: token) ]
        @handlers[method] ? @handlers[method].call(args) : default_response(method)
      end
    end

    private

      def default_response(method)
        case method
        when :get_accounts, :get_positions then []
        when :get_funds then { "currency" => "SGD", "total_assets" => "0", "cash" => "0" }
        else { records: [], truncated: false }
        end
      end
  end

  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @item = moomoo_items(:connected_item)
    @item.update!(access_token_expires_at: 1.day.from_now)
    @account = moomoo_accounts(:main_account)
    use_budget(500)
  end

  test "discovers each shared account, keeping only a masked card number" do
    @provider.on(:get_accounts) do
      [
        account_row,
        account_row("account_id" => 2222, "enable_market" => [ 5 ], "account_card_number" => "1001234500002222"),
        account_row("account_id" => 3333, "enable_market" => [ 7 ], "account_card_number" => "1001234500003333")
      ]
    end

    import

    securities = @item.moomoo_accounts.find_by!(moomoo_account_id: "1234567890123456")
    assert_equal "securities", securities.account_kind
    assert_equal "SGD", securities.currency
    assert_equal [ 1, 2, 6 ], securities.enable_markets
    assert_equal "••3456", securities.account_number_mask
    assert_equal "1234567890123456", securities.raw_account_payload["account_id"]
    assert_not securities.raw_account_payload.key?("account_card_number")
    assert_not securities.raw_account_payload.key?("univs_account_card_number")

    futures = @item.moomoo_accounts.find_by!(moomoo_account_id: "2222")
    assert_equal "futures", futures.account_kind
    assert_equal "moomoo SG ••2222", futures.name
    assert_not futures.linkable?
    assert_equal "crypto", @item.moomoo_accounts.find_by!(moomoo_account_id: "3333").account_kind

    assert_equal [ "1234567890123456" ], @provider.calls_to(:get_funds).map { |args| args[:acc_id] }
  end

  test "balances come from funds, asked for in the account currency" do
    @provider.on(:get_funds) { |args| { "currency" => args[:currency], "total_assets" => "25000.50", "cash" => "700.25" } }
    @provider.on(:get_positions) { [ { "code" => "US.AAPL", "qty" => "10" } ] }

    import

    assert_equal [ "SGD" ], @provider.calls_to(:get_funds).map { |args| args[:currency] }
    @account.reload
    assert_equal BigDecimal("25000.50"), @account.current_balance
    assert_equal BigDecimal("700.25"), @account.cash_balance
    assert_equal [ { "code" => "US.AAPL", "qty" => "10" } ], @account.raw_positions_payload
  end

  test "funds in another currency leave a linked account's balance alone" do
    link_account!
    @provider.on(:get_funds) { { "currency" => "USD", "total_assets" => "1", "cash" => "1" } }

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "error").count }, 1 do
      import
    end

    @account.reload
    assert_equal "SGD", @account.currency
    assert_equal BigDecimal("10000"), @account.current_balance
  end

  test "an account not linked yet takes the currency moomoo reports" do
    @provider.on(:get_funds) { { "currency" => "USD", "total_assets" => "1200", "cash" => "200" } }

    import

    @account.reload
    assert_equal "USD", @account.currency
    assert_equal BigDecimal("1200"), @account.current_balance
  end

  test "funds in another currency without a total keep the account's currency" do
    @provider.on(:get_funds) { { "currency" => "USD", "cash" => "200" } }

    import

    @account.reload
    assert_equal "SGD", @account.currency
    assert_equal BigDecimal("10000"), @account.current_balance
  end

  test "a first sync reads the newest window, then backfills two years a window at a time" do
    import

    %w[SG US HK].each do |market|
      fills = windows(:get_fills_history, market)
      assert_equal 9, fills.size, market
      assert_equal [ micros(89.days.ago), micros(Time.current) ], fills.first
      assert_equal micros(730.days.ago), fills.last.first
      fills.each_cons(2) { |newer, older| assert_equal newer.first, older.last }
      fills.each { |from, to| assert_operator to - from, :<=, micros(89.days.from_now) - micros(Time.current) }
      assert_equal fills, windows(:get_orders_history, market)
      assert @account.reload.history_cursor(market)["complete"], market
    end

    assert_equal %w[HK SG US], @provider.calls_to(:get_today_fills).map { |args| args[:trd_market] }.sort
    assert_not @item.history_backfill_pending?
  end

  test "a later sync re-reads a week before the last one and skips finished backfills" do
    complete_history!(newest: 2.days.ago)

    import

    %w[SG US HK].each do |market|
      assert_equal [ [ micros(9.days.ago), micros(Time.current) ] ], windows(:get_fills_history, market)
      assert_equal micros(Time.current), @account.reload.history_cursor(market)["newest_us"]
    end
  end

  test "a long gap since the last sync is read in windows of 89 days" do
    complete_history!(newest: 200.days.ago)

    import

    assert_equal [
      [ micros(89.days.ago), micros(Time.current) ],
      [ micros(178.days.ago), micros(89.days.ago) ],
      [ micros(207.days.ago), micros(178.days.ago) ]
    ], windows(:get_fills_history, "US")
  end

  test "a fill seen twice is kept once, in its latest version" do
    complete_history!(newest: 1.day.ago)
    original = fill("deal-1", status: "OK", updated: 2.hours.ago)
    cancelled = fill("deal-1", status: "CANCELLED", updated: 10.minutes.ago)
    @provider.on(:get_today_fills) { |args| args[:trd_market] == "US" ? page(original) : page }
    @provider.on(:get_fills_history) { |args| args[:trd_market] == "US" ? page(cancelled) : page }

    import

    fills = @account.reload.raw_fills_payload
    assert_equal 1, fills.size
    assert_equal "CANCELLED", fills.first["status"]
    assert_equal "US", fills.first["trd_market"]
  end

  test "running out of budget keeps what was fetched and the next sync carries on" do
    use_budget(20)

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "info").where("message LIKE ?", "%request budget%").count }, 1 do
      result = import
      assert result[:success]
      assert result[:backfill_pending]
      assert_equal 20, result[:requests_used]
    end

    # One backfill window per market, so every market advanced evenly.
    %w[SG US HK].each do |market|
      cursor = @account.reload.history_cursor(market)
      assert_equal micros(178.days.ago), cursor["oldest_us"], market
      assert_not cursor["complete"]
    end
    assert @item.reload.good?

    use_budget(500)
    import

    backfill = windows(:get_fills_history, "SG").drop(1)
    assert_equal micros(178.days.ago), backfill.first.last
    assert @account.reload.history_cursor("SG")["complete"]
  end

  test "a market that keeps failing does not hold up the others" do
    @provider.on(:get_fills_history) do |args|
      raise Provider::Moomoo::MoomooError.new("market not open", :api_error, code: -1) if args[:trd_market] == "HK"

      page
    end

    import

    @account.reload
    assert @account.history_cursor("SG")["complete"]
    assert @account.history_cursor("US")["complete"]
    assert_equal({ "failures" => 1 }, @account.history_cursor("HK"))
    assert @item.reload.good?
  end

  test "a market that fails on every sync stops counting as pending after the limit and is still retried" do
    @provider.on(:get_fills_history) do |args|
      raise Provider::Moomoo::MoomooError.new("market not open", :api_error, code: -1) if args[:trd_market] == "HK"

      page
    end
    stalled = -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%syncs in a row%").count }

    (MoomooAccount::HISTORY_FAILURE_LIMIT - 1).times { |i| assert import[:backfill_pending], "import #{i + 1}" }
    assert_difference stalled, 1 do
      assert_not import[:backfill_pending]
    end
    assert_not @item.reload.history_backfill_pending?
    assert_equal MoomooAccount::HISTORY_FAILURE_LIMIT, @account.reload.history_cursor("HK")["failures"]

    @provider.on(:get_fills_history) { page }
    assert_difference -> { @provider.calls_to(:get_fills_history).count { |args| args[:trd_market] == "HK" } }, 9 do
      import
    end
    cursor = @account.reload.history_cursor("HK")
    assert cursor["complete"]
    assert_nil cursor["failures"]
  end

  test "a backfill window refused on every sync is counted once per sync" do
    retention = micros(365.days.ago)
    @provider.on(:get_fills_history) do |args|
      raise Provider::Moomoo::MoomooError.new("time out of range", :api_error, code: -1) if args[:start_us] < retention

      page
    end

    (MoomooAccount::HISTORY_FAILURE_LIMIT - 1).times { |i| assert import[:backfill_pending], "import #{i + 1}" }
    assert_not import[:backfill_pending]

    %w[SG US HK].each do |market|
      cursor = @account.reload.history_cursor(market)
      assert_equal MoomooAccount::HISTORY_FAILURE_LIMIT, cursor["failures"], market
      assert_equal micros(356.days.ago), cursor["oldest_us"], market
      assert_not cursor["complete"], market
    end
  end

  test "a rate limit is not counted as a market failure" do
    @provider.on(:get_today_fills) { raise Provider::Moomoo::MoomooError.new("slow down", :rate_limited, code: -12011) }

    assert import[:backfill_pending]

    %w[SG US HK].each { |market| assert_nil @account.reload.history_cursor(market)["failures"], market }
  end

  test "an account the user stopped sharing does not keep the connection pending" do
    link_account!
    partial = { "newest_us" => micros(1.day.ago), "oldest_us" => micros(178.days.ago) }
    @account.update!(history_cursors: %w[SG US HK].index_with { partial })
    other_row = account_row("account_id" => 555, "account_card_number" => "1001234500000555")
    @provider.on(:get_accounts) { [ other_row ] }

    assert_not import[:backfill_pending]
    assert_not @item.reload.history_backfill_pending?
    assert @account.reload.history_backfill_pending?

    # Shared again: its backfill resumes and counts until it is done.
    @provider.on(:get_accounts) { [ account_row, other_row ] }
    use_budget(20)
    assert import[:backfill_pending]
    assert @item.reload.history_backfill_pending?

    use_budget(500)
    assert_not import[:backfill_pending]
    assert_not @item.reload.history_backfill_pending?
    assert @account.reload.history_cursor("US")["complete"]
  end

  test "the part of a window past the page cap is read on, not skipped" do
    reached = 40.days.ago
    @provider.on(:get_fills_history) do |args|
      next page unless args[:trd_market] == "US"

      if args[:end_us] == micros(Time.current)
        { records: [ fill("newest", status: "OK", updated: reached) ], truncated: true, reason: :page_limit }
      elsif args[:start_us] <= micros(60.days.ago) && args[:end_us] >= micros(60.days.ago)
        page(fill("oldest", status: "OK", updated: 60.days.ago))
      else
        page
      end
    end

    import

    assert_equal %w[newest oldest], @account.reload.raw_fills_payload.map { |fill| fill["deal_id"] }
    assert_equal micros(reached + 1.second), windows(:get_fills_history, "US").second.last
    assert @account.history_cursor("US")["complete"]
  end

  test "a capped window of fills without an updated_time is read on from their create time" do
    reached = 40.days.ago
    @provider.on(:get_fills_history) do |args|
      next page unless args[:trd_market] == "US"

      if args[:end_us] == micros(Time.current)
        { records: [ fill("newest", status: "OK", updated: reached).except("updated_time") ], truncated: true, reason: :page_limit }
      elsif args[:start_us] <= micros(60.days.ago) && args[:end_us] >= micros(60.days.ago)
        page(fill("oldest", status: "OK", updated: 60.days.ago).except("updated_time"))
      else
        page
      end
    end

    import

    assert_equal %w[newest oldest], @account.reload.raw_fills_payload.map { |fill| fill["deal_id"] }
    assert_equal micros(reached + 1.second), windows(:get_fills_history, "US").second.last
  end

  test "a later sync reads a capped window down to its start" do
    complete_history!(newest: 30.days.ago)
    reached = 10.days.ago
    @provider.on(:get_fills_history) do |args|
      next page unless args[:trd_market] == "US"

      if args[:end_us] == micros(Time.current)
        { records: [ fill("newest", status: "OK", updated: reached) ], truncated: true, reason: :page_limit }
      elsif args[:end_us] == micros(reached + 1.second)
        page(fill("oldest", status: "OK", updated: 35.days.ago))
      else
        page
      end
    end

    import

    assert_equal [ [ micros(37.days.ago), micros(Time.current) ], [ micros(37.days.ago), micros(reached + 1.second) ] ], windows(:get_fills_history, "US")
    assert_equal %w[newest oldest], @account.reload.raw_fills_payload.map { |fill| fill["deal_id"] }
  end

  test "cash logs past the page cap are read on from a day after the oldest row" do
    complete_history!(newest: 1.day.ago)
    @provider.on(:get_cash_logs) do |args|
      if args[:end_us] == micros(Time.current)
        { records: [ { "transaction_name" => "Deposit", "created_time" => "2026-09-01 10:00:00", "cash_change" => "1.00", "balance" => "2.00" } ], truncated: true, reason: :page_limit }
      else
        page
      end
    end

    import

    assert_equal micros(Time.zone.parse("2026-09-02 10:00:00")), @provider.calls_to(:get_cash_logs).second[:end_us]
  end

  # About 53 rows a day: each answer is 40 pages and reaches 15 days back.
  test "a first sync leaves busy cash logs past the newest answer to the backfill, behind the trade history" do
    use_budget(250)
    @provider.on(:get_cash_logs) do |args|
      window_end = Provider::Moomoo.from_micros(args[:end_us])
      oldest = window_end - 15.days
      next page(cash_log(window_end - 1.hour)) if oldest <= Provider::Moomoo.from_micros(args[:begin_us])

      39.times { @budget.consume! }
      { records: [ cash_log(window_end - 1.hour), cash_log(oldest) ], truncated: true, reason: :page_limit }
    end

    import

    @account.reload
    %w[SG US HK].each { |market| assert @account.history_cursor(market)["complete"], market }
    assert_equal Time.current, @account.cash_logs_synced_through
    reached = @account.cash_logs_backfilled_from
    assert_operator reached, :<, 14.days.ago

    travel 1.day
    @item.update!(access_token_expires_at: 1.day.from_now)
    use_budget(250)
    import

    assert_includes @provider.calls_to(:get_cash_logs).map { |args| args[:end_us] }, micros(reached)
    assert_operator @account.reload.cash_logs_backfilled_from, :<, reached
  end

  test "a later sync after a long pause leaves the busy cash logs one answer can't reach to the backfill, behind the trade history" do
    use_budget(250)
    partial = { "newest_us" => micros(1.day.ago), "oldest_us" => micros(300.days.ago) }
    @account.update!(history_cursors: %w[SG US HK].index_with { partial }, cash_logs_synced_through: 120.days.ago, cash_logs_backfilled_from: 730.days.ago)
    busy_cash_logs!
    paused_at = 123.days.ago

    import

    @account.reload
    %w[SG US HK].each { |market| assert @account.history_cursor(market)["complete"], market }
    assert_equal Time.current, @account.cash_logs_synced_through
    reached = @account.cash_logs_gap_until
    assert_operator reached, :<, 14.days.ago
    assert_equal paused_at, @account.cash_logs_gap_from

    windows = []
    3.times do
      travel 1.day
      @item.update!(access_token_expires_at: 1.day.from_now)
      use_budget(250)
      import
      windows.concat(@provider.calls_to(:get_cash_logs).map { |args| [ args[:begin_us], args[:end_us] ] })
    end

    assert_nil @account.reload.cash_logs_gap_until
    # Later syncs carried on where the first stopped, down to the pause.
    assert_includes windows.map(&:last), micros(reached)
    assert_includes windows.map(&:first), micros(paused_at)
  end

  test "a later sync after a long pause leaves the busy trades one answer can't reach to the backfill, keeping its place" do
    use_budget(250)
    complete_history!(newest: 200.days.ago)
    # Each US answer is 40 pages and reaches 10 days back.
    @provider.on(:get_fills_history) do |args|
      next page unless args[:trd_market] == "US"

      window_end = Provider::Moomoo.from_micros(args[:end_us])
      oldest = window_end - 10.days
      next page(fill("f#{args[:end_us]}", status: "OK", updated: window_end - 1.hour)) if oldest <= Provider::Moomoo.from_micros(args[:start_us])

      39.times { @budget.consume! }
      { records: [ fill("f#{args[:end_us]}", status: "OK", updated: oldest) ], truncated: true, reason: :page_limit }
    end
    paused_at = 207.days.ago

    import

    cursor = @account.reload.history_cursor("US")
    assert_equal micros(Time.current), cursor["newest_us"]
    assert_equal micros(paused_at), cursor["gap_from_us"]
    reached = cursor["gap_until_us"]
    assert_operator reached, :<, micros(30.days.ago)
    assert @item.reload.history_backfill_pending?
    %w[SG HK].each { |market| assert_equal micros(Time.current), @account.history_cursor(market)["newest_us"], market }

    us_windows = []
    5.times do
      travel 1.day
      @item.update!(access_token_expires_at: 1.day.from_now)
      use_budget(250)
      import
      us_windows.concat(windows(:get_fills_history, "US"))
    end

    cursor = @account.reload.history_cursor("US")
    assert_nil cursor["gap_until_us"]
    assert cursor["complete"]
    assert_not @item.reload.history_backfill_pending?
    # Later syncs carried on where the first stopped, down to the pause.
    assert_includes us_windows.map(&:last), reached
    assert_includes us_windows.map(&:first), micros(paused_at)
  end

  test "a window that stops on a repeated page_flag is logged as cut short" do
    complete_history!(newest: 1.day.ago)
    @provider.on(:get_fills_history) { |args| args[:trd_market] == "US" ? { records: [], truncated: true, reason: :repeated_page_flag } : page }

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%fills and orders (US)%page_flag it had already sent%").count }, 1 do
      assert import[:success]
    end
  end

  # Retrying it would get the same answer and hold up the older windows, so
  # the rest is skipped, and the sync summary says so.
  test "a window cut short with nothing to resume from is reported among the sync's failures" do
    complete_history!(newest: 1.day.ago)
    @account.update!(cash_logs_synced_through: 1.day.ago, cash_logs_backfilled_from: 730.days.ago)
    @provider.on(:get_fills_history) { |args| args[:trd_market] == "US" ? { records: [], truncated: true, reason: :repeated_page_flag } : page }
    @provider.on(:get_cash_logs) { { records: [], truncated: true, reason: :repeated_page_flag } }

    result = import

    assert result[:success]
    assert_equal [ [ :trade_history_skipped, "US" ], [ :cash_logs_skipped, nil ] ], result[:failures].map { |failure| failure.values_at(:what, :market) }
    assert result[:failures].all? { |failure| failure[:message].include?("short with nothing to resume from") }
  end

  test "a window cut short that can resume is not a failure" do
    complete_history!(newest: 1.day.ago)
    reached = 3.days.ago
    @provider.on(:get_fills_history) do |args|
      if args[:trd_market] == "US" && args[:end_us] == micros(Time.current)
        { records: [ fill("newest", status: "OK", updated: reached) ], truncated: true, reason: :page_limit }
      else
        page
      end
    end

    assert_empty import[:failures]
  end

  test "today's fills cut short are logged; the trade history covers the rest" do
    complete_history!(newest: 1.day.ago)
    @provider.on(:get_today_fills) { |args| args[:trd_market] == "US" ? { records: [ fill("today", status: "OK", updated: 1.hour.ago) ], truncated: true, reason: :page_limit } : page }

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%today's fills (US) exceeded%the trade history covers the rest%").count }, 1 do
      assert import[:success]
    end
    assert_includes @account.reload.raw_fills_payload.map { |fill| fill["deal_id"] }, "today"
  end

  test "funds that can't be used keep the positions and date of the last snapshot" do
    link_account!
    last_sync = Time.zone.parse("2026-10-23 12:00:00")
    stored = [ { "code" => "SG.D05", "qty" => "50" } ]
    @account.update!(raw_positions_payload: stored, last_positions_sync: last_sync)
    @provider.on(:get_positions) { [ { "code" => "SG.D05", "qty" => "80" } ] }

    [ { "currency" => "USD", "total_assets" => "1", "cash" => "1" }, { "currency" => "SGD", "cash" => "1" } ].each do |funds|
      @provider.on(:get_funds) { funds }

      import

      @account.reload
      assert @account.snapshot_stale?
      assert_equal stored, @account.raw_positions_payload
      assert_equal last_sync, @account.last_positions_sync
      assert_equal BigDecimal("10000"), @account.current_balance
    end
  end

  test "an account moomoo won't answer for does not hold up the others" do
    @provider.on(:get_accounts) { [ account_row, account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }
    @provider.on(:get_funds) do |args|
      raise Provider::Moomoo::MoomooError.new("moomoo GET /funds failed (200 / -1): account restricted", :api_error, code: -1) if args[:acc_id] == "555"

      { "currency" => "SGD", "total_assets" => "12345.67", "cash" => "1" }
    end

    result = nil
    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%balances and positions%").count }, 1 do
      result = import
    end

    assert result[:success]
    assert_equal BigDecimal("12345.67"), @account.reload.current_balance
    assert @item.moomoo_accounts.find_by!(moomoo_account_id: "555").snapshot_stale?
    assert_not @account.reload.snapshot_stale?
    assert_equal [ "1234567890123456" ], @provider.calls_to(:get_today_fills).map { |args| args[:acc_id] }.uniq
    assert @item.reload.good?
  end

  test "an account Sure can't read stops counting as importing after the failure limit" do
    @provider.on(:get_accounts) { [ account_row, account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }
    @provider.on(:get_funds) do |args|
      raise Provider::Moomoo::MoomooError.new("moomoo GET /funds failed (200 / -1): account restricted", :api_error, code: -1) if args[:acc_id] == "555"

      { "currency" => "SGD", "total_assets" => "1", "cash" => "1" }
    end

    (MoomooAccount::HISTORY_FAILURE_LIMIT - 1).times { |i| assert import[:backfill_pending], "import #{i + 1}" }
    assert_not import[:backfill_pending]
    assert_not @item.reload.history_backfill_pending?
    assert @account.reload.history_cursor("US")["complete"]
    unread = @item.moomoo_accounts.find_by!(moomoo_account_id: "555")
    %w[SG US HK].each { |market| assert_equal MoomooAccount::HISTORY_FAILURE_LIMIT, unread.history_cursor(market)["failures"], market }

    # Readable again: its history imports and the count is cleared.
    @provider.on(:get_funds) { { "currency" => "SGD", "total_assets" => "1", "cash" => "1" } }
    assert_not import[:backfill_pending]
    %w[SG US HK].each do |market|
      cursor = unread.reload.history_cursor(market)
      assert cursor["complete"], market
      assert_nil cursor["failures"], market
    end
  end

  test "the only account, when moomoo keeps refusing it, stops counting as importing after the failure limit" do
    @provider.on(:get_funds) { raise Provider::Moomoo::MoomooError.new("moomoo GET /funds failed (200 / -1): account restricted", :api_error, code: -1) }

    MoomooAccount::HISTORY_FAILURE_LIMIT.times do
      assert_equal :api_error, assert_raises(Provider::Moomoo::MoomooError) { import }.error_type
    end

    assert @item.reload.good?
    assert_not @item.history_backfill_pending?
    %w[SG US HK].each { |market| assert_equal MoomooAccount::HISTORY_FAILURE_LIMIT, @account.reload.history_cursor(market)["failures"], market }
  end

  test "a missing permission on one of several accounts does not ask for a reconnect" do
    @provider.on(:get_accounts) { [ account_row, account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }
    @provider.on(:get_positions) do |args|
      raise Provider::Moomoo::MoomooError.new("blocked", :scope_missing, code: -12009) if args[:acc_id] == "555"

      []
    end

    assert import[:success]
    assert @item.reload.good?
  end

  test "an import that can read no account still fails" do
    @provider.on(:get_accounts) { [ account_row, account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }
    @provider.on(:get_funds) { raise Provider::Moomoo::MoomooError.new("moomoo down", :server_error, status: 503) }

    assert_equal :server_error, assert_raises(Provider::Moomoo::MoomooError) { import }.error_type
  end

  test "a rate limit on any account's balances ends the import" do
    @provider.on(:get_accounts) { [ account_row, account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }
    @provider.on(:get_funds) do |args|
      raise Provider::Moomoo::MoomooError.new("slow down", :rate_limited, code: -12011) if args[:acc_id] == "555"

      { "currency" => "SGD", "total_assets" => "1", "cash" => "1" }
    end

    assert_equal :rate_limited, assert_raises(Provider::Moomoo::MoomooError) { import }.error_type
  end

  test "a moomoo Japan margin account is listed but never fetched" do
    @provider.on(:get_accounts) do
      [ account_row, account_row("account_id" => 8888, "security_firm" => "FUTUJP", "enable_market" => [ 15, 2 ], "acc_type" => "margin", "account_card_number" => "1001234500008888") ]
    end

    import

    margin = @item.moomoo_accounts.find_by!(moomoo_account_id: "8888")
    assert_equal "jp_margin", margin.account_kind
    assert_not margin.linkable?
    assert_equal [ "1234567890123456" ], @provider.calls_to(:get_funds).map { |args| args[:acc_id] }
    assert_equal 1, @item.reload.unlinked_accounts_count
  end

  test "what could not be fetched is returned with the result" do
    @provider.on(:get_cash_logs) { raise Provider::Moomoo::MoomooError.new("blocked", :scope_missing, code: -12009) }
    @provider.on(:get_fills_history) do |args|
      raise Provider::Moomoo::MoomooError.new("market not open", :api_error, code: -1) if args[:trd_market] == "HK"

      page
    end

    result = import

    assert_nil result[:rate_limited_at]
    failures = result[:failures].map { |failure| failure.values_at(:what, :market, :account) }
    assert_includes failures, [ :recent_trade_history, "HK", @account.name ]
    assert_includes failures, [ :recent_cash_logs, nil, @account.name ]
  end

  test "a failed early refresh does not fail the sync while the stored token is valid" do
    @item.update!(access_token_expires_at: 3.minutes.from_now)
    Provider::Moomoo.any_instance.expects(:refresh_access_token).once
      .raises(Provider::Moomoo::MoomooError.new("unavailable", :token_failed, status: 503))

    assert import[:success]

    assert_equal [ "test_access" ], @provider.calls.map { |_method, args| args[:token] }.uniq
    assert_not_empty @provider.calls_to(:get_fills_history)
    assert @item.reload.good?
  end

  test "a refresh that fails once the token has expired postpones the remaining optional work" do
    @provider.on(:get_positions) do
      travel 2.days
      []
    end
    Provider::Moomoo.any_instance.expects(:refresh_access_token).once
      .raises(Provider::Moomoo::MoomooError.new("unavailable", :token_failed, status: 503))

    assert import[:success]

    assert_empty @provider.calls_to(:get_today_fills)
    assert_empty @provider.calls_to(:get_cash_logs)
    assert @item.reload.good?
  end

  test "a missing permission on cash logs is a partial failure" do
    @provider.on(:get_cash_logs) { raise Provider::Moomoo::MoomooError.new("blocked", :scope_missing, code: -12009) }

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%cash logs%").count }, 1 do
      assert import[:success]
    end

    assert @item.reload.good?
  end

  test "a missing permission on positions asks for a reconnect" do
    @provider.on(:get_positions) { raise Provider::Moomoo::MoomooError.new("blocked", :scope_missing, code: -12009) }

    error = assert_raises(Provider::Moomoo::MoomooError) { import }

    assert_equal :scope_missing, error.error_type
    @item.reload
    assert @item.requires_update?
    assert_equal "scope_missing", @item.reauth_reason
  end

  test "a refused access token is refreshed once and the request retried" do
    refused = false
    @provider.on(:get_accounts) do
      unless refused
        refused = true
        raise Provider::Moomoo::MoomooError.new("expired", :token_expired, code: -12102)
      end
      [ account_row ]
    end
    Provider::Moomoo.any_instance.expects(:refresh_access_token).once
      .returns(access_token: "fresh", refresh_token: nil, expires_in: 7200, scope: "")

    import

    assert_equal %w[test_access fresh], @provider.calls_to(:get_accounts).map { |args| args[:token] }
    assert_equal "fresh", @item.reload.access_token
  end

  test "a freshly issued token being refused too asks for a reconnect" do
    @provider.on(:get_accounts) { raise Provider::Moomoo::MoomooError.new("expired", :token_expired, code: -12102) }
    Provider::Moomoo.any_instance.expects(:refresh_access_token).once
      .returns(access_token: "fresh", refresh_token: nil, expires_in: 7200, scope: "")

    error = assert_raises(Provider::Moomoo::MoomooError) { import }

    assert_equal :token_rejected, error.error_type
    @item.reload
    assert @item.requires_update?
    assert_equal "token_rejected", @item.reauth_reason
  end

  test "a rate limit that outlasts the retries postpones the remaining optional work" do
    @provider.on(:get_today_fills) { raise Provider::Moomoo::MoomooError.new("slow down", :rate_limited, code: -12011) }

    result = import

    assert result[:success]
    assert_equal Time.current, result[:rate_limited_at]
    assert_equal 1, @provider.calls_to(:get_today_fills).size
    assert_empty @provider.calls_to(:get_fills_history)
    assert_empty @provider.calls_to(:get_cash_logs)
    assert @item.reload.good?
  end

  test "cash logs are stored once each and never imported" do
    complete_history!(newest: 1.day.ago)
    @account.update!(cash_logs_synced_through: 200.days.ago)
    row = { "transaction_name" => "Deposit", "created_time" => "2026-10-01 10:00:00", "cash_change" => "100.00", "balance" => "100.00", "symbol" => "", "stock_name" => "" }
    @provider.on(:get_cash_logs) { page(row) }

    assert_no_difference -> { Entry.count } do
      import
    end

    assert_operator @provider.calls_to(:get_cash_logs).size, :>, 1
    logs = @account.reload.raw_cash_logs_payload
    assert_equal 1, logs.size
    assert_equal "100.00", logs.first["cash_change"]
    assert logs.first["digest"].present?
    assert_equal micros(730.days.ago), micros(@account.cash_logs_backfilled_from)
  end

  test "an account no longer shared is not fetched; a linked one keeps its data" do
    link_account!
    unlinked = @item.moomoo_accounts.create!(moomoo_account_id: "999", name: "Other", currency: "SGD", account_kind: "securities")
    @provider.on(:get_accounts) { [ account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%no longer authorized%").count }, 1 do
      import
    end

    assert MoomooAccount.exists?(@account.id)
    assert_not MoomooAccount.exists?(unlinked.id)
    assert_equal [ "555" ], @provider.calls_to(:get_funds).map { |args| args[:acc_id] }
  end

  # The kept account got no listing of this import, so its other rows
  # would never update.
  test "an empty authorized-account list leaves a kept account's rows out of setup" do
    @account.update!(role: "stocks", last_seen_at: 1.day.ago)
    link_account!
    unseen_cash = @item.moomoo_accounts.create!(
      moomoo_account_id: @account.moomoo_account_id, primary_moomoo_account: @account, role: "cash",
      name: "moomoo SG ••3456 (USD cash)", currency: "USD", account_kind: "securities"
    )
    @provider.on(:get_accounts) { [] }

    assert import[:success]

    assert MoomooAccount.exists?(unseen_cash.id)
    assert_equal Time.current, @item.reload.accounts_listed_at
    assert_equal 0, @item.unlinked_accounts_count
    assert_empty @item.fetched_moomoo_accounts
    assert_not @item.history_backfill_pending?
  end

  test "a list of only other accounts leaves a kept account's rows out of setup" do
    @account.update!(role: "stocks", last_seen_at: 1.day.ago)
    link_account!
    @item.moomoo_accounts.create!(
      moomoo_account_id: @account.moomoo_account_id, primary_moomoo_account: @account, role: "cash",
      name: "moomoo SG ••3456 (USD cash)", currency: "USD", account_kind: "securities"
    )
    @provider.on(:get_accounts) { [ account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }

    import

    assert_equal [ "555" ], @item.reload.fetched_moomoo_accounts.map(&:moomoo_account_id)
    assert_equal [ "555" ], @item.setup_candidate_moomoo_accounts.map(&:moomoo_account_id)
  end

  test "an empty authorized-account list drops the unlinked accounts and keeps a linked one" do
    link_account!
    unlinked = @item.moomoo_accounts.create!(moomoo_account_id: "999", name: "Other", currency: "SGD", account_kind: "securities")
    @provider.on(:get_accounts) { [] }

    assert import[:success]

    assert MoomooAccount.exists?(@account.id)
    assert_not MoomooAccount.exists?(unlinked.id)
    assert_empty @provider.calls_to(:get_funds)
  end

  test "orders keep only the fields trades need" do
    complete_history!(newest: 1.day.ago)
    order = { "order_id" => "o1", "code" => "US.AAPL", "currency" => "USD", "security_type" => "STOCK", "remark" => "note", "aux_price" => "0.000" }
    @provider.on(:get_orders_history) { |args| args[:trd_market] == "US" ? page(order) : page }

    import

    assert_equal({ "order_id" => "o1", "code" => "US.AAPL", "currency" => "USD", "security_type" => "STOCK" }, @account.reload.orders_map["o1"])
  end

  test "a linked account that holds a second currency keeps its link for the home currency's stocks and offers the rest to set up" do
    linked = link_account!
    split_answers!

    import

    @account.reload
    assert_equal linked, @account.current_account
    assert_equal [ "SGD", "stocks", "moomoo SG ••3456 (SGD stocks)" ], [ @account.currency, @account.role, @account.name ]
    assert_equal [ BigDecimal("1925"), BigDecimal("0") ], [ @account.current_balance, @account.cash_balance ]

    rows = @account.currency_accounts.order(:currency, :role).map do |row|
      [ row.currency, row.role, row.name, row.current_balance, row.cash_balance, row.moomoo_account_id, row.current_account ]
    end
    assert_equal [
      [ "SGD", "cash", "moomoo SG ••3456 (SGD cash)", BigDecimal("1300"), BigDecimal("1300"), "1234567890123456", nil ],
      [ "USD", "cash", "moomoo SG ••3456 (USD cash)", BigDecimal("1000"), BigDecimal("1000"), "1234567890123456", nil ],
      [ "USD", "stocks", "moomoo SG ••3456 (USD stocks)", BigDecimal("1800"), BigDecimal("0"), "1234567890123456", nil ]
    ], rows
    usd = @account.currency_accounts.find_by!(currency: "USD", role: "stocks")
    assert_equal [ "FUTUSG", "margin", "securities", "••3456" ], [ usd.security_firm, usd.acc_type, usd.account_kind, usd.account_number_mask ]
    assert_equal 3, @item.unlinked_accounts_count

    # A later sync updates the same rows.
    travel 1.day
    import
    assert_equal 4, @item.moomoo_accounts.where(moomoo_account_id: "1234567890123456").count
    assert_equal [ "1234567890123456" ], @provider.calls_to(:get_funds).map { |args| args[:acc_id] }.uniq
  end

  test "a linked account of a currency without positions or trades becomes its cash account" do
    linked = link_account!
    split_answers!
    @provider.on(:get_positions) { [ split_positions.last ] }
    @provider.on(:get_funds) { split_funds(sg: "1287", us: "990").merge("total_assets" => "4940") }

    import

    @account.reload
    assert_equal [ linked, "cash", "moomoo SG ••3456 (SGD cash)" ], [ @account.current_account, @account.role, @account.name ]
    assert_equal [ BigDecimal("1300"), BigDecimal("1300") ], [ @account.current_balance, @account.cash_balance ]
    assert_equal [ [ "USD", "cash" ], [ "USD", "stocks" ] ], @account.currency_accounts.order(:role).pluck(:currency, :role)
  end

  test "a currency account split before keeps its row, and its link, as the stocks account" do
    split_answers!
    usd = @account.currency_accounts.create!(
      moomoo_item: @item, moomoo_account_id: @account.moomoo_account_id, currency: "USD", name: "moomoo SG ••3456 (USD)", account_kind: "securities"
    )
    linked = @item.family.accounts.create!(name: "moomoo USD", balance: 0, currency: "USD", accountable: Investment.new)
    usd.ensure_account_provider!(linked)

    import

    usd.reload
    assert_equal [ "stocks", "moomoo SG ••3456 (USD stocks)", linked ], [ usd.role, usd.name, usd.current_account ]
    assert_equal BigDecimal("1800"), usd.current_balance
    assert_nil @account.reload.cash_row_for("USD").current_account
  end

  test "an account that holds only its home currency stays one account" do
    @provider.on(:get_funds) { split_funds(sg: "2600", us: "0") }
    @provider.on(:get_positions) { [ split_positions.first ] }

    import

    @account.reload
    assert_empty @account.currency_accounts
    assert_equal "moomoo SG ••3456", @account.name
    assert_equal BigDecimal("6865"), @account.current_balance
  end

  test "a linked account that holds only a foreign currency stays one account" do
    linked = link_account!
    split_answers!
    @provider.on(:get_funds) do
      { "currency" => "SGD", "total_assets" => "4040", "cash" => "0", "funds_assets" => "1700", "securities_assets" => "2340",
        "sg_net_cash_power" => "0", "us_net_cash_power" => "1300" }
    end
    @provider.on(:get_positions) { [ split_positions.last ] }

    import

    @account.reload
    assert_empty @account.currency_accounts
    assert_equal linked, @account.current_account
    assert_equal "moomoo SG ••3456", @account.name
    assert_equal BigDecimal("4040"), @account.current_balance
  end

  test "figures per currency that don't add up leave a split account at its last snapshot" do
    split_answers!
    import
    last_sync = @account.reload.last_positions_sync

    travel 1.day
    @provider.on(:get_funds) { split_funds(sg: "1287", us: "500") }
    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "error").where("message LIKE ?", "%74.5%").count }, 1 do
      result = import
      assert_equal [ :balances_and_positions ], result[:failures].map { |failure| failure[:what] }
    end

    @account.reload
    usd = @account.currency_accounts.find_by!(currency: "USD", role: "cash")
    assert_equal last_sync, @account.last_positions_sync
    assert @account.snapshot_stale?
    assert usd.snapshot_stale?
    assert_equal BigDecimal("1925"), @account.current_balance
    assert_equal BigDecimal("1000"), usd.current_balance
  end

  test "figures per currency that don't add up keep an account not split yet whole" do
    split_answers!
    @provider.on(:get_funds) { split_funds(sg: "1287", us: "500") }

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%not split by currency%").count }, 1 do
      import
    end

    @account.reload
    assert_empty @account.currency_accounts
    assert_not @account.snapshot_stale?
    assert_equal BigDecimal("6865"), @account.current_balance
  end

  test "an account no longer shared keeps its data while one of its currencies is linked" do
    split_answers!
    import
    usd = @account.currency_accounts.find_by!(currency: "USD", role: "stocks")
    usd.ensure_account_provider!(@item.family.accounts.create!(name: "moomoo USD", balance: 0, currency: "USD", accountable: Investment.new))
    @provider.on(:get_accounts) { [ account_row("account_id" => 555, "account_card_number" => "1001234500000555") ] }

    import

    assert MoomooAccount.exists?(@account.id)
    assert MoomooAccount.exists?(usd.id)
  end

  private

    def use_budget(limit)
      @budget = Provider::Moomoo::RequestBudget.new(limit)
      previous = @provider
      @provider = FakeProvider.new(@budget)
      @provider.on(:get_accounts) { [ account_row ] }
      previous&.handlers&.each { |method, handler| @provider.on(method, &handler) }
    end

    def import
      MoomooItem::Importer.new(@item, provider: @provider, budget: @budget).import
    end

    def account_row(overrides = {})
      {
        "account_id" => 1234567890123456,
        "security_firm" => "FUTUSG",
        "enable_market" => [ 6, 2, 1 ],
        "acc_type" => "margin",
        "univs_account_card_number" => "1001234567893456",
        "account_card_number" => "1001234567893456"
      }.merge(overrides)
    end

    # 1,287 SGD and 990 USD of buying power at 1.3 come to 99% of the 2,600
    # SGD of cash and funds; the positions are 1,925 SGD and 1,800 USD.
    def split_answers!
      @item.update!(access_token_expires_at: 1.week.from_now)
      (Date.current..Date.current + 2).each do |date|
        ExchangeRate.find_or_create_by!(from_currency: "USD", to_currency: "SGD", date: date) { |rate| rate.rate = 1.3 }
      end
      @provider.on(:get_funds) { split_funds(sg: "1287", us: "990") }
      @provider.on(:get_positions) { split_positions }
    end

    def split_funds(sg:, us:)
      {
        "currency" => "SGD", "total_assets" => "6865", "cash" => "0", "funds_assets" => "2600", "securities_assets" => "4265",
        "sg_net_cash_power" => sg, "us_net_cash_power" => us
      }
    end

    def split_positions
      [
        { "position_side" => "LONG", "code" => "SG.D05", "security_type" => "STOCK", "qty" => "50", "currency" => "SGD", "market_val" => "1925.00" },
        { "position_side" => "LONG", "code" => "US.AAPL", "security_type" => "STOCK", "qty" => "10", "currency" => "USD", "market_val" => "1800.00" }
      ]
    end

    def link_account!
      account = @item.family.accounts.create!(name: "moomoo", balance: 0, currency: "SGD", accountable: Investment.new)
      @account.ensure_account_provider!(account)
      account
    end

    def complete_history!(newest:)
      cursor = { "newest_us" => micros(newest), "oldest_us" => micros(730.days.ago), "complete" => true }
      @account.update!(history_cursors: %w[SG US HK].index_with { cursor })
    end

    def windows(method, market)
      @provider.calls_to(method).select { |args| args[:trd_market] == market }.map { |args| [ args[:start_us], args[:end_us] ] }
    end

    def page(*records)
      { records: records, truncated: false }
    end

    def fill(deal_id, status:, updated:)
      {
        "deal_id" => deal_id, "order_id" => "o-#{deal_id}", "trd_side" => "BUY", "code" => "US.AAPL",
        "qty" => "1", "price" => "100", "create_time" => micros(updated), "updated_time" => micros(updated), "status" => status
      }
    end

    def cash_log(time)
      { "transaction_name" => "Fee", "created_time" => time.strftime("%Y-%m-%d %H:%M:%S"), "cash_change" => "-1.00", "balance" => "100.00" }
    end

    # About 53 rows a day: an answer for more than 15 days is 40 pages and
    # reaches 15 days back.
    def busy_cash_logs!
      @provider.on(:get_cash_logs) do |args|
        window_end = Provider::Moomoo.from_micros(args[:end_us])
        oldest = window_end - 15.days
        next page(cash_log(window_end - 1.hour)) if oldest <= Provider::Moomoo.from_micros(args[:begin_us])

        39.times { @budget.consume! }
        { records: [ cash_log(window_end - 1.hour), cash_log(oldest) ], truncated: true, reason: :page_limit }
      end
    end

    def micros(time)
      Provider::Moomoo.to_micros(time)
    end
end
