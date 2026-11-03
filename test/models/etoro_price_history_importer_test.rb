require "test_helper"

class EtoroPriceHistoryImporterTest < ActiveSupport::TestCase
  NEW_YORK = ActiveSupport::TimeZone["America/New_York"]
  OFFLINE_REASON = "etoro_prices"

  # eToro's two candle endpoints over a made-up history, answering as eToro
  # would at the time of the call. `prices` are each instrument's closes on
  # today's shares by trading day, and `splits` the days its raw closes
  # switch to new shares, with their ratios. The split-adjusted candles take
  # a split in `adjusted_lag` sessions after its switch and lack their
  # newest `adjusted_missing`; a session's raw candle is sent `raw_delay`
  # after it closes. An instrument in `failing` raises its error. The
  # split-adjusted candles raise `adjusted_failure`, or are none when it is
  # :empty, and put the days in `adjusted_glitch` off by its factors.
  class FakeEtoro
    attr_reader :calls
    attr_accessor :adjusted_missing, :adjusted_failure, :adjusted_glitch

    def initialize(symbols:, prices:, splits: {}, adjusted_lag: 0, adjusted_missing: 0, raw_delay: 0.seconds, failing: {})
      @symbols = symbols
      @prices = prices
      @splits = splits
      @adjusted_lag = adjusted_lag
      @adjusted_missing = adjusted_missing
      @raw_delay = raw_delay
      @failing = failing
      @adjusted_glitch = {}
      @calls = []
    end

    # eToro sends the candles that open within the window.
    def fetch_daily_candles(instrument_id, from:, to: Date.current.tomorrow)
      @calls << [ :raw, instrument_id ]
      raise @failing[instrument_id] if @failing.key?(instrument_id)

      window = from.in_time_zone("UTC")...to.in_time_zone("UTC")
      results = sessions(instrument_id).filter_map do |day|
        next unless closes_at(day) + @raw_delay <= Time.current && window.cover?(opens_at(day))

        { "time" => opens_at(day).utc.iso8601, "close" => raw_close(instrument_id, day).to_s("F") }
      end
      { "symbol" => @symbols.fetch(instrument_id), "results" => results.reverse }
    end

    def fetch_adjusted_candles(instrument_id, interval:)
      @calls << [ interval, instrument_id ]
      raise ArgumentError, "only daily candles are made up" unless interval == "OneDay"
      raise @adjusted_failure if @adjusted_failure.is_a?(Exception)
      return [] if @adjusted_failure == :empty

      days = sessions(instrument_id).select { |day| closes_at(day) <= Time.current }
      days = days.first([ days.size - @adjusted_missing, 0 ].max).last(1000)
      days.reverse.map do |day|
        { "instrumentID" => instrument_id, "fromDate" => "#{day.iso8601}T00:00:00Z", "close" => adjusted_close(instrument_id, day).to_f }
      end
    end

    def count(kind, instrument_id = nil)
      @calls.count { |call_kind, id| call_kind == kind && (instrument_id.nil? || id == instrument_id) }
    end

    private

      def sessions(instrument_id)
        @prices.fetch(instrument_id).keys.sort
      end

      def opens_at(day)
        NEW_YORK.local(day.year, day.month, day.day, 17) - 1.day
      end

      def closes_at(day)
        NEW_YORK.local(day.year, day.month, day.day, 17)
      end

      # As traded on the day, on the shares of the time.
      def raw_close(instrument_id, day)
        factor = @splits.fetch(instrument_id, {}).reduce(Rational(1)) { |product, (on, ratio)| on > day ? product * ratio : product }
        (@prices.fetch(instrument_id).fetch(day) * factor.numerator / factor.denominator).round(4)
      end

      def adjusted_close(instrument_id, day)
        factor = @splits.fetch(instrument_id, {}).reduce(Rational(1)) do |product, (on, ratio)|
          on > day && taken_in?(instrument_id, on) ? product * ratio : product
        end
        (raw_close(instrument_id, day) * factor.denominator * @adjusted_glitch.fetch(day, 1) / factor.numerator).round(4)
      end

      def taken_in?(instrument_id, switch)
        days = sessions(instrument_id)
        at = days[days.index(switch) + @adjusted_lag]
        at.present? && closes_at(at) <= Time.current
      end
  end

  setup do
    # Saturday morning in New York: Friday 23 October is the newest closed session.
    travel_to Time.utc(2026, 10, 24, 12)

    @item = etoro_items(:configured_item)
    @etoro_account = etoro_accounts(:main_account)
    @account = families(:dylan_family).accounts.create!(name: "eToro", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @etoro_account.ensure_account_provider!(@account)
    @acme = listing("ACME", "XNAS")
    describe(3001, "ACME", exchange_id: 4)
    hold(position(501, 3001, opened: "2026-06-01T14:00:00Z"))
    @provider = mock("etoro_provider")
    ExchangeRate.stubs(:provider).returns(nil)
  end

  test "a first sync stores eToro's closes adjusted to today's shares and keeps the splits it found" do
    split_on = Date.new(2026, 9, 1)
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: restate(adjusted, from: Date.new(2026, 5, 25), splits: { split_on => 2 }))
    expect_adjusted(3001, "OneDay", adjusted)

    result = import

    assert_empty result.partial_failures
    assert_equal every_day(adjusted, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
    assert_equal [ "USD" ], @acme.prices.distinct.pluck(:currency)
    history = history(3001)
    assert_equal [ [ "2026-09-01", "2" ] ], split_list(history)
    assert_equal [ "2026-06-01", "2026-10-23" ], history.values_at("from", "through")
    assert_equal [ @acme.id, "USD" ], history.values_at("security_id", "currency")
    assert_equal [ true, OFFLINE_REASON ], [ @acme.reload.offline?, @acme.offline_reason ]
  end

  test "dates candles by their New York session across both clock changes and keeps one candle a day" do
    hold(position(501, 3001, opened: "2025-10-27T14:00:00Z"))
    candles = [
      { "time" => "2025-10-30T21:00:00Z", "close" => "101" },   # Friday 31 October, summer time
      { "time" => "2025-11-02T22:00:00Z", "close" => "102" },   # Monday 3 November, winter time
      { "time" => "2026-03-03T22:00:00Z", "close" => "103" },   # Wednesday 4 March
      { "time" => "2026-03-04T00:00:00Z", "close" => "25.75" }, # a stray candle for the same day
      { "time" => "2026-03-05T22:00:00Z", "close" => "104" },   # Friday 6 March, winter time
      { "time" => "2026-03-08T21:00:00Z", "close" => "105" }    # Monday 9 March, summer time
    ]
    @provider.expects(:fetch_daily_candles).with(3001, from: Date.new(2025, 10, 19)).returns({ "symbol" => "ACME/USD", "results" => candles.reverse })
    expected = {
      Date.new(2025, 10, 31) => BigDecimal("101"),
      Date.new(2025, 11, 3) => BigDecimal("102"),
      Date.new(2026, 3, 4) => BigDecimal("103"),
      Date.new(2026, 3, 6) => BigDecimal("104"),
      Date.new(2026, 3, 9) => BigDecimal("105")
    }
    expect_adjusted(3001, "OneDay", expected.merge(Date.new(2025, 10, 24) => BigDecimal("100")))

    import

    assert_equal expected, stored_prices(@acme).slice(*expected.keys)
    assert_equal BigDecimal("101"), stored_prices(@acme)[Date.new(2025, 11, 1)], "a Saturday takes Friday's close"
  end

  test "a session still trading is left for a later sync" do
    travel_to Time.utc(2026, 10, 23, 19) # Friday afternoon in New York
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: adjusted.select { |day, _| day >= Date.new(2026, 5, 25) })
    expect_adjusted(3001, "OneDay", adjusted)

    import

    assert_equal Date.new(2026, 10, 22), @acme.prices.maximum(:date)
    assert_equal "2026-10-22", history(3001)["through"]
  end

  test "London prices quoted in pence are stored in pounds" do
    london = listing("LONX", "XLON")
    describe(3002, "LONX.L", exchange_id: 7)
    hold(position(502, 3002, opened: "2026-10-19T09:00:00Z"))
    (Date.new(2026, 10, 12)..Date.new(2026, 10, 23)).each { |day| ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: day, rate: 1.33) }
    pence = { Date.new(2026, 10, 19) => BigDecimal("1250"), Date.new(2026, 10, 20) => BigDecimal("1262.5"), Date.new(2026, 10, 23) => BigDecimal("1300") }
    expect_raw(3002, from: Date.new(2026, 10, 11), symbol: "LONX.l/GBX", closes: pence)
    expect_adjusted(3002, "OneDay", pence.merge(Date.new(2026, 10, 16) => BigDecimal("1240")))

    import

    assert_equal({
      Date.new(2026, 10, 19) => BigDecimal("12.5"),
      Date.new(2026, 10, 20) => BigDecimal("12.625"),
      Date.new(2026, 10, 21) => BigDecimal("12.625"),
      Date.new(2026, 10, 22) => BigDecimal("12.625"),
      Date.new(2026, 10, 23) => BigDecimal("13")
    }, stored_prices(london))
    assert_equal [ "GBP" ], london.prices.distinct.pluck(:currency)
  end

  test "names the currency eToro quotes a listing in, a minor unit as its currency" do
    assert_equal [ "USD", 1 ], EtoroItem::PriceHistoryImporter.quote_currency("ABCD/USD")
    assert_equal [ "GBP", 100 ], EtoroItem::PriceHistoryImporter.quote_currency("LONX.l/GBX")
    assert_equal [ "GBP", 100 ], EtoroItem::PriceHistoryImporter.quote_currency("ABC.L/GBp")
    assert_equal [ "ZAR", 100 ], EtoroItem::PriceHistoryImporter.quote_currency("JNBX.J/ZAc")
    assert_equal [ "ILS", 100 ], EtoroItem::PriceHistoryImporter.quote_currency("TLVX.TA/ILA")
    assert_equal [ "HKD", 1 ], EtoroItem::PriceHistoryImporter.quote_currency("4321.HK/HKD")
    assert_nil EtoroItem::PriceHistoryImporter.quote_currency("ODD")
  end

  test "a price in a currency without exchange rates is not stored, and the next sync tries again" do
    hong_kong = listing("HKGX", "XHKG")
    describe(3003, "HKGX.HK", exchange_id: 21)
    hold(position(503, 3003, opened: "2026-10-19T02:00:00Z"))
    closes = { Date.new(2026, 10, 19) => BigDecimal("26.8"), Date.new(2026, 10, 20) => BigDecimal("27") }
    expect_raw(3003, from: Date.new(2026, 10, 11), symbol: "HKGX.HK/HKD", closes: closes)
    expect_adjusted(3003, "OneDay", closes.merge(Date.new(2026, 10, 16) => BigDecimal("26.5")))

    result = import

    assert_empty hong_kong.prices
    assert_equal [ :price_history ], result.partial_failures.map { |failure| failure[:what] }
    assert_equal I18n.t("etoro_items.sync.partial_failures.price_history_missing_rates", currency: "HKD", count: 2), result.partial_failures.first[:message]
    assert_nil history(3003)["priced_through"]
  end

  # The history goes on recording the prices kept, so that they are handed
  # back with the security.
  test "a security eToro starts quoting in a currency without exchange rates keeps its prices and their record" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "100")
    closes = { Date.new(2026, 10, 21) => BigDecimal("100"), Date.new(2026, 10, 22) => BigDecimal("101"), Date.new(2026, 10, 23) => BigDecimal("102") }
    expect_raw(3001, from: Date.new(2026, 10, 20), symbol: "ACME/HKD", closes: closes)
    expect_raw(3001, from: Date.new(2026, 5, 24), symbol: "ACME/HKD", closes: closes)

    result = import

    assert_equal [ Date.new(2026, 10, 20), Date.new(2026, 10, 21) ], @acme.prices.where(currency: "USD").order(:date).pluck(:date)
    assert_equal [ "USD", "2026-06-01", "2026-10-21" ], history(3001).values_at("currency", "written_from", "priced_through")
    assert_equal [ :price_history ], result.partial_failures.map { |failure| failure[:what] }
  end

  test "prices go only on offline securities no provider prices that no other account holds" do
    online = listing("ONLN", nil, offline: false)
    provided = listing("PRVD", nil)
    provided.update_columns(price_provider: "yahoo_finance")
    disabled = listing("DSBL", nil, offline_reason: "provider_disabled")
    shared = listing("SHRD", nil)
    accounts(:investment).holdings.create!(security: shared, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    failed = listing("FAIL", nil, offline_reason: "health_check_failed")
    kept = listing("KEPT", nil, offline_reason: "health_check_failed")
    Security::Price.create!(security: kept, date: Date.new(2026, 10, 16), price: 8, currency: "USD")
    [ [ 3011, "ONLN" ], [ 3012, "PRVD" ], [ 3013, "DSBL" ], [ 3014, "SHRD" ], [ 3015, "FAIL" ], [ 3016, "KEPT" ] ].each { |id, symbol| describe(id, symbol) }
    hold(*(3011..3016).map { |id| position(id, id, opened: "2026-10-19T14:00:00Z") })
    closes = { Date.new(2026, 10, 19) => BigDecimal("10"), Date.new(2026, 10, 20) => BigDecimal("11") }
    expect_raw(3015, from: Date.new(2026, 10, 11), closes: closes)
    expect_adjusted(3015, "OneDay", closes.merge(Date.new(2026, 10, 16) => BigDecimal("9")))

    import

    assert_equal [ failed.id ], Security::Price.where(security: [ online, provided, disabled, shared, failed ]).distinct.pluck(:security_id)
    assert_equal [ [ Date.new(2026, 10, 16), BigDecimal("8") ] ], kept.prices.pluck(:date, :price), "a provider's prices stay the provider's"
    assert_equal "health_check_failed", kept.reload.offline_reason
    assert_equal OFFLINE_REASON, failed.reload.offline_reason
    assert_equal [ false, nil ], [ online.reload.offline?, online.offline_reason ]
    assert_nil provided.reload.offline_reason
    assert_equal "provider_disabled", disabled.reload.offline_reason
    assert_nil shared.reload.offline_reason
  end

  test "an account split into copies prices the securities its copy accounts hold" do
    @etoro_account.update!(display_mode: :copies)
    copy = @etoro_account.copy_accounts.create!(etoro_item: @item, mirror_id: 7, etoro_account_id: "copy-7", name: "eToro copy: trader", currency: "USD", display_mode: :copies)
    copy_account = families(:dylan_family).accounts.create!(name: "eToro copy", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    copy.ensure_account_provider!(copy_account)
    copy_account.holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: adjusted)
    expect_adjusted(3001, "OneDay", adjusted)

    import

    assert_equal every_day(adjusted, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
    assert_equal OFFLINE_REASON, @acme.reload.offline_reason
  end

  test "leaving copies keeps the prices of the securities the copy accounts still hold" do
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    @acme.update!(offline_reason: OFFLINE_REASON)
    copy = @etoro_account.copy_accounts.create!(etoro_item: @item, mirror_id: 7, etoro_account_id: "copy-7", name: "eToro copy: trader", currency: "USD", display_mode: :copies)
    copy_account = families(:dylan_family).accounts.create!(name: "eToro copy", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    copy.ensure_account_provider!(copy_account)
    # The sync that leaves copies imports prices before the copy account is emptied.
    copy_account.holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    assert_no_difference -> { copy_account.syncs.count } do
      import
    end

    assert_equal 2, @acme.prices.count
    assert_equal @acme.id, history(3001)["security_id"]
  end

  test "a copy's account unlinked hands back on the next sync the prices of the securities it still holds" do
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    @etoro_account.update!(display_mode: :copies)
    copy = @etoro_account.copy_accounts.create!(etoro_item: @item, mirror_id: 7, etoro_account_id: "copy-7", name: "eToro copy: trader", currency: "USD", display_mode: :copies)
    copy_account = families(:dylan_family).accounts.create!(name: "eToro copy", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    copy.ensure_account_provider!(copy_account)
    copy_account.holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    copy_account.account_providers.reload.destroy_all
    assert_equal 2, @acme.prices.count, "unlinking hands back none by itself"

    # The unlinked account is another account holding the security.
    assert_difference -> { copy_account.syncs.count }, 1 do
      import
    end

    assert_empty @acme.prices
    assert_nil @acme.reload.offline_reason
    assert_nil history(3001)["security_id"]
  end

  test "hands a security back to Sure without eToro's prices once eToro no longer prices it" do
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    @acme.update!(offline_reason: OFFLINE_REASON)
    @acme.update_columns(price_provider: "yahoo_finance")

    import

    assert_equal [ true, nil ], [ @acme.reload.offline?, @acme.offline_reason ]
    assert_nil history(3001)["security_id"]
    assert_empty @acme.prices
  end

  test "a security another account starts holding loses the prices eToro gave it, and that account is synced again" do
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    @acme.update!(offline_reason: OFFLINE_REASON)
    other = accounts(:investment)
    other.holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    assert_difference -> { other.syncs.count }, 1 do
      import
    end

    assert_empty @acme.prices
    assert_nil @acme.reload.offline_reason
    assert_nil history(3001)["security_id"]
  end

  test "a security a price provider's check found while eToro priced it goes to the provider without eToro's prices" do
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    @acme.update!(offline: false, offline_reason: OFFLINE_REASON)

    import

    assert_equal [ false, nil ], [ @acme.reload.offline?, @acme.offline_reason ]
    assert_empty @acme.prices
    assert_nil history(3001)["security_id"]
  end

  test "an account no longer linked keeps the prices another linked connection gives the security" do
    @etoro_account.account_provider.destroy!
    # A sync running while the account was unlinked saves its claim after
    # the unlink handed the security back.
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    # The account is linked to a newer connection, which prices ACME too.
    newer = etoro_items(:pending_setup_item)
    newer.update!(raw_instruments_payload: { "3001" => @item.reload.instruments_map["3001"] })
    newer.etoro_accounts.create!(name: "eToro", etoro_account_id: "etoro_trading_2", currency: "USD").ensure_account_provider!(@account)

    import

    assert_equal OFFLINE_REASON, @acme.reload.offline_reason
    assert_equal 2, @acme.prices.count
    assert_nil history(3001)["security_id"]
  end

  test "a connection the account is linked to anew prices the days of the trades it keeps, and takes all of eToro's prices back" do
    prices = prices_between(Date.new(2024, 2, 1), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })
    close(trade(601, 3001, units: 5, investment: 500, opened: "2024-03-01T15:00:00Z", closed: "2024-09-03T15:00:00Z"))
    sync_trades(etoro)
    assert_equal Date.new(2024, 3, 1), @acme.prices.minimum(:date)

    # The account is linked to a new connection, whose trade history starts later.
    @etoro_account.account_provider.destroy!
    newer = etoro_items(:pending_setup_item)
    newer.update!(raw_instruments_payload: { "3001" => @item.reload.instruments_map["3001"].except("price_history") })
    newer_account = newer.etoro_accounts.create!(
      name: "eToro", etoro_account_id: "etoro_trading_2", currency: "USD",
      raw_positions_payload: [ position(501, 3001, opened: "2026-06-01T14:00:00Z") ], raw_trades_payload: []
    )
    newer_account.ensure_account_provider!(@account)
    import_newer = -> { EtoroItem::PriceHistoryImporter.new(newer.reload, newer_account.reload, provider: etoro).import }
    import_newer.call
    import_with(etoro)

    accounts(:investment).holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    import_newer.call

    assert_empty @acme.prices
    assert_nil @acme.reload.offline_reason
  end

  test "a trade added to the account by hand does not take eToro's prices back to its day" do
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices_between(Date.new(2024, 6, 3), Date.new(2026, 10, 23)) })
    # On the shares of its day, while eToro's prices are on today's.
    @account.entries.create!(date: Date.new(2025, 2, 3), name: "Buy ACME", amount: 2000, currency: "USD", entryable: Trade.new(security: @acme, qty: 10, price: 200, currency: "USD"))

    import_with(etoro)

    assert_equal [ Date.new(2026, 6, 1), "2026-06-01" ], [ @acme.prices.minimum(:date), history(3001)["priced_from"] ]
  end

  test "an account disabled hands its securities back, and another account holding one is synced again" do
    seed_history(3001, through: Date.new(2026, 10, 23), close: "100")
    @acme.update!(offline_reason: OFFLINE_REASON)
    other = accounts(:investment)
    other.holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    @account.disable!

    assert_difference -> { other.syncs.count }, 1 do
      assert_empty import.partial_failures
    end

    assert_empty @acme.prices
    assert_nil @acme.reload.offline_reason
  end

  test "a security a health check brings online during the sync gets no prices from eToro" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    acme = @acme
    etoro = Class.new(FakeEtoro) do
      define_method(:fetch_daily_candles) do |instrument_id, **options|
        acme.update_columns(offline: false, last_health_check_at: Time.current) # the health check finds a provider for it
        super(instrument_id, **options)
      end
    end.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })

    each_close([ Date.new(2026, 10, 23) ]) { import_with(etoro) }

    assert_empty @acme.prices
    assert_equal [ false, nil ], [ @acme.reload.offline?, @acme.offline_reason ]
    assert_nil history(3001)["currency"]
  end

  test "a connection deleted while its sync stores prices leaves no security with eToro's prices" do
    ids = (3001..3003).to_a
    securities = [ @acme ] + ids.drop(1).map do |id|
      describe(id, "SYM#{id}", exchange_id: 5)
      listing("SYM#{id}", "XNYS")
    end
    hold(*ids.map { |id| position(id, id, opened: "2026-06-01T14:00:00Z") })
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    item = @item
    reads = 0
    etoro = Class.new(FakeEtoro) do
      define_method(:fetch_daily_candles) do |instrument_id, **options|
        if (reads += 1) == 2 # the user deletes the connection, and the deletion runs, during the sync
          item.reload.unlink_all!(dry_run: false)
          item.destroy_later
          DestroyJob.perform_now(EtoroItem.find(item.id))
        end
        super(instrument_id, **options)
      end
    end.new(symbols: ids.to_h { |id| [ id, "SYM#{id}/USD" ] }, prices: ids.to_h { |id| [ id, prices ] })

    import_with(etoro)

    assert_not EtoroItem.exists?(item.id)
    assert_empty Security::Price.where(security: securities)
    assert_equal [ nil ] * 3, securities.map { |security| security.reload.offline_reason }
  end

  test "a release takes only the prices eToro stored, also after a sync short of exchange rates" do
    london = listing("LONX", "XLON")
    describe(3002, "LONX.L", exchange_id: 7)
    hold(position(502, 3002, opened: "2026-10-12T09:00:00Z"))
    (Date.new(2026, 10, 19)..Date.new(2026, 10, 23)).each { |day| ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: day, rate: 1.33) }
    pence = prices_between(Date.new(2026, 10, 12), Date.new(2026, 10, 23)) { 1250 }
    expect_raw(3002, from: Date.new(2026, 10, 4), symbol: "LONX.l/GBX", closes: pence)
    expect_adjusted(3002, "OneDay", pence.merge(Date.new(2026, 10, 2) => BigDecimal("1250")))

    import
    assert_equal Date.new(2026, 10, 19), london.prices.minimum(:date)
    # Prices from before the first day eToro wrote, such as a user's own.
    stored_before = (Date.new(2025, 1, 6)..Date.new(2025, 1, 10)).to_a
    stored_before.each { |day| Security::Price.create!(security: london, date: day, price: 9.99, currency: "GBP") }
    london.update_columns(price_provider: "twelve_data") # a user chose a price provider for it
    import

    assert_equal stored_before, london.prices.order(:date).pluck(:date)
  end

  test "a later sync reads only the days since and keeps the splits it knows" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "100")
    expect_raw(3001, from: Date.new(2026, 10, 20), closes: {
      Date.new(2026, 10, 21) => BigDecimal("100"), Date.new(2026, 10, 22) => BigDecimal("101"), Date.new(2026, 10, 23) => BigDecimal("102")
    })
    @provider.expects(:fetch_adjusted_candles).never

    import

    assert_equal [ BigDecimal("100"), BigDecimal("101"), BigDecimal("102") ], stored_prices(@acme).values_at(Date.new(2026, 10, 21), Date.new(2026, 10, 22), Date.new(2026, 10, 23))
    assert_equal [ "2026-10-23", [] ], history(3001).values_at("through", "splits")
    assert_equal BigDecimal("102"), BigDecimal(history(3001)["close"])
  end

  test "a jump in the days since has the splits checked again and the earlier prices restated" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "200", price: 200)
    split_on = Date.new(2026, 10, 22)
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    raw = restate(adjusted, from: Date.new(2026, 5, 25), splits: { split_on => 2 })
    expect_raw(3001, from: Date.new(2026, 10, 20), closes: raw)
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: raw)
    expect_adjusted(3001, "OneDay", adjusted)

    import

    assert_equal every_day(adjusted, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
    assert_equal [ [ "2026-10-22", "2" ] ], split_list(history(3001))
  end

  test "prices written afresh for another security still have the days since checked for a split" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "200", price: 200)
    renamed = Security.create!(ticker: "ACMEOLD", offline: true)
    instruments = @item.reload.instruments_map.deep_dup
    instruments["3001"]["price_history"]["security_id"] = renamed.id
    @item.update!(raw_instruments_payload: instruments)
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: restate(adjusted, from: Date.new(2026, 5, 25), splits: { Date.new(2026, 10, 22) => 2 }))
    expect_adjusted(3001, "OneDay", adjusted)

    import

    assert_equal [ [ "2026-10-22", "2" ] ], split_list(history(3001))
    assert_equal every_day(adjusted, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "asks eToro nothing more until another session has closed" do
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: adjusted.select { |day, _| day >= Date.new(2026, 5, 25) })
    expect_adjusted(3001, "OneDay", adjusted)
    import
    stored = @acme.prices.order(:date).pluck(:date, :price, :updated_at)

    import
    travel_to Time.utc(2026, 10, 25, 20) # Sunday: no session has closed since Friday
    import

    assert_equal stored, @acme.prices.order(:date).pluck(:date, :price, :updated_at)
  end

  test "daily syncs store every session's close, and the days between at the close before them" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })

    each_close(Date.new(2026, 10, 9)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "a session eToro sends late is stored on a later sync, and a sync soon after a read asks nothing" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, raw_delay: 12.hours)

    each_close([ Date.new(2026, 10, 9) ]) { import_with(etoro) }
    assert_equal Date.new(2026, 10, 8), @acme.prices.maximum(:date), "Friday's candle comes on Saturday"

    travel_to NEW_YORK.local(2026, 10, 9, 20)
    assert_no_difference -> { etoro.calls.size } do
      import_with(etoro)
    end

    travel_to NEW_YORK.local(2026, 10, 10, 9)
    import_with(etoro)
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 9)), stored_prices(@acme)
  end

  test "a split eToro's adjusted history takes in a session after its raw closes switch is still applied" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 21) => 3 } }, adjusted_lag: 1)

    each_close(Date.new(2026, 10, 19)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal [ [ "2026-10-21", "3" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "a split eToro's adjusted history has no day after yet is applied once it has" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 21) => 3 } }, adjusted_missing: 1)

    each_close(Date.new(2026, 10, 19)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal [ [ "2026-10-21", "3" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "a split eToro's adjusted history takes in a session after the first sync's newest one is applied the next day" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 21) => 3 } }, adjusted_lag: 1)

    each_close(Date.new(2026, 10, 21)..Date.new(2026, 10, 22)) { import_with(etoro) }

    assert_equal [ [ "2026-10-21", "3" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 22)), stored_prices(@acme)
  end

  test "a split eToro's adjusted history has no day after yet on the first sync is applied the next day" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 21) => 3 } }, adjusted_missing: 1)

    each_close(Date.new(2026, 10, 21)..Date.new(2026, 10, 22)) { import_with(etoro) }

    assert_equal [ [ "2026-10-21", "3" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 22)), stored_prices(@acme)
  end

  test "a split just before the first day bought is no jump to check again" do
    hold(position(501, 3001, opened: "2026-10-21T14:00:00Z"))
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 19) => 2 } })

    each_close(Date.new(2026, 10, 21)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal 1, etoro.count("OneDay")
    assert_equal [ [], nil ], history(3001).values_at("splits", "jump")
    assert_equal every_day(prices, from: Date.new(2026, 10, 21), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "a jump after the last day an instrument was held is no jump to check again" do
    hold
    close(trade(601, 3001, opened: "2026-06-01T14:00:00Z", closed: "2026-10-01T15:00:00Z"))
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { |day| day < Date.new(2026, 10, 21) ? 100 : 50 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })

    each_close([ Date.new(2026, 10, 23) ]) { import_with(etoro) }

    assert_equal [ "2026-10-23", nil ], history(3001).values_at("through", "jump")
    assert_equal Date.new(2026, 10, 1), @acme.prices.maximum(:date)
  end

  test "two splits eToro's adjusted history takes in late are both applied" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 28))
    splits = { Date.new(2026, 10, 20) => 2, Date.new(2026, 10, 22) => 3 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => splits }, adjusted_lag: 2)

    each_close(Date.new(2026, 10, 16)..Date.new(2026, 10, 28)) { import_with(etoro) }

    assert_equal [ [ "2026-10-20", "2" ], [ "2026-10-22", "3" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 28)), stored_prices(@acme)
  end

  test "a split while an earlier jump is checked again is applied once eToro's adjusted history takes it in" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 28)) { |day| day < Date.new(2026, 10, 19) ? 100 : 55 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 26) => 2 } }, adjusted_lag: 1)

    each_close(Date.new(2026, 10, 16)..Date.new(2026, 10, 28)) { import_with(etoro) }

    assert_equal [ [ "2026-10-26", "2" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 28)), stored_prices(@acme)
  end

  test "a split too small to make the raw closes jump is found by the weekly check of an instrument still held" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 21) => Rational(5, 4) } })

    each_close(Date.new(2026, 10, 16)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal [ [ "2026-10-21", "5/4" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
    assert_equal 2, etoro.count("OneDay"), "the first sync's and the weekly check's"
  end

  test "a change of basis by a ratio no split has that only the weekly check sees is logged and not applied" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 21) => Rational(9, 8) } })

    each_close(Date.new(2026, 10, 16)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal [ [], 2 ], [ split_list(history(3001)), etoro.count("OneDay") ], "the first sync's and the weekly check's"
    assert DebugLogEntry.where(provider_key: "etoro").where("message LIKE ?", "%3001%ratio no split has%").exists?
  end

  test "a split check eToro sends no split-adjusted days for is made again, and finds a split taken in late" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 11, 6)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 15) => Rational(6, 5) } }, adjusted_lag: 2)

    each_close(Date.new(2026, 10, 9)..Date.new(2026, 10, 22)) { import_with(etoro) }
    etoro.adjusted_failure = :empty
    each_close([ Date.new(2026, 10, 23) ]) { import_with(etoro) }
    etoro.adjusted_failure = nil
    each_close(Date.new(2026, 10, 26)..Date.new(2026, 11, 6)) { import_with(etoro) }

    assert_equal [ [ "2026-10-15", "6/5" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 11, 6)), stored_prices(@acme)
  end

  test "a split check eToro's split-adjusted history stops short for leaves the days it did not compare to the next one" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 11, 6)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 15) => Rational(6, 5) } }, adjusted_lag: 2)

    each_close(Date.new(2026, 10, 9)..Date.new(2026, 10, 22)) { import_with(etoro) }
    etoro.adjusted_missing = 8
    each_close([ Date.new(2026, 10, 23) ]) { import_with(etoro) }
    assert_equal [ "2026-10-23", "2026-10-13" ], history(3001).values_at("checked", "compared")
    etoro.adjusted_missing = 0
    each_close(Date.new(2026, 10, 26)..Date.new(2026, 11, 6)) { import_with(etoro) }

    assert_equal [ [ "2026-10-15", "6/5" ] ], split_list(history(3001))
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 11, 6)), stored_prices(@acme)
  end

  test "a bonus issue large enough to make the raw closes jump is applied on the day eToro's prices switch" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 23) => Rational(4, 3) } })

    each_close(Date.new(2026, 10, 19)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal [ [ [ "2026-10-23", "4/3" ] ], nil ], [ split_list(history(3001)), history(3001)["jump"] ]
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "eToro's split-adjusted history a day behind the closes keeps the split checks a week apart" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 30))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, adjusted_missing: 1)

    each_close(Date.new(2026, 10, 9)..Date.new(2026, 10, 30)) { import_with(etoro) }

    assert_equal [ 4, "2026-10-30" ], [ etoro.count("OneDay"), history(3001)["checked"] ], "the first read's, and the checks of 16, 23 and 30 October"
  end

  test "a check's newest day alone off in eToro's split-adjusted history by a bonus issue's ratio is no split" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 30))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })

    each_close(Date.new(2026, 10, 9)..Date.new(2026, 10, 15)) { import_with(etoro) }
    etoro.adjusted_glitch = { Date.new(2026, 10, 16) => BigDecimal("1.05") }
    each_close([ Date.new(2026, 10, 16) ]) { import_with(etoro) }
    etoro.adjusted_glitch = {}
    each_close(Date.new(2026, 10, 19)..Date.new(2026, 10, 30)) { import_with(etoro) }

    assert_equal [], split_list(history(3001))
    assert_operator history(3001)["checked"], :>, "2026-10-16"
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 30)), stored_prices(@acme)
  end

  test "the weekly split check waits for requests to spare" do
    EtoroItem::PriceHistoryImporter.stubs(:max_requests_per_sync).returns(1)
    seed_history(3001, through: Date.new(2026, 10, 22), close: "100", checked: Date.new(2026, 10, 9))
    expect_raw(3001, from: Date.new(2026, 10, 21), closes: { Date.new(2026, 10, 22) => BigDecimal("100"), Date.new(2026, 10, 23) => BigDecimal("101") })
    @provider.expects(:fetch_adjusted_candles).never

    assert_empty import.partial_failures
    assert_equal "2026-10-09", history(3001)["checked"]
  end

  test "the split checks a sync has requests to spare for go to the instruments checked longest ago" do
    ids = (3001..3006).to_a
    ids.drop(1).each do |id|
      listing("SYM#{id}", "XNYS")
      describe(id, "SYM#{id}", exchange_id: 5)
    end
    hold(*ids.map { |id| position(id, id, opened: "2026-06-01T14:00:00Z") })
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: ids.to_h { |id| [ id, "SYM#{id}/USD" ] }, prices: ids.to_h { |id| [ id, prices ] })
    each_close([ Date.new(2026, 10, 9) ]) { import_with(etoro) }
    # A read of each instrument, and one split check a sync.
    EtoroItem::PriceHistoryImporter.stubs(:max_requests_per_sync).returns(ids.size + 1 + EtoroItem::PriceHistoryImporter::JUMP_REQUESTS)

    each_close(Date.new(2026, 10, 12)..Date.new(2026, 10, 23)) { import_with(etoro) }

    assert_equal ids, ids.select { |id| history(id)["checked"] > "2026-10-09" }, "each checked again since its first read"
  end

  test "split checks leave requests to spare for a jump found after them" do
    ids = (3001..3004).to_a
    ids.drop(1).each do |id|
      listing("SYM#{id}", "XNYS")
      describe(id, "SYM#{id}", exchange_id: 5)
    end
    hold(*ids.map { |id| position(id, id, opened: "2026-06-01T14:00:00Z") })
    steady = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    halved = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { |day| day < Date.new(2026, 10, 23) ? 100 : 50 }
    etoro = FakeEtoro.new(symbols: ids.to_h { |id| [ id, "SYM#{id}/USD" ] }, prices: ids.to_h { |id| [ id, id == 3003 ? halved : steady ] })
    each_close([ Date.new(2026, 10, 16) ]) { import_with(etoro) }
    EtoroItem::PriceHistoryImporter.stubs(:max_requests_per_sync).returns(6)

    result = nil
    each_close([ Date.new(2026, 10, 23) ]) { result = import_with(etoro) }

    assert_empty result.partial_failures
    assert_equal [ "2026-10-23", "2026-10-23", "2026-10-22", "2026-10-23" ], ids.map { |id| history(id)["through"] }, "the jump is checked again on the next sync"
  end

  test "split checks eToro fails to answer wait for a later sync, and the prices read go in" do
    ids = (3001..3004).to_a
    ids.drop(1).each do |id|
      listing("SYM#{id}", "XNYS")
      describe(id, "SYM#{id}", exchange_id: 5)
    end
    hold(*ids.map { |id| position(id, id, opened: "2026-06-01T14:00:00Z") })
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: ids.to_h { |id| [ id, "SYM#{id}/USD" ] }, prices: ids.to_h { |id| [ id, prices ] })
    each_close([ Date.new(2026, 10, 16) ]) { import_with(etoro) }
    etoro.adjusted_failure = Provider::Etoro::TransientError.new("eToro withheld its market data (status 403)", status_code: 403)
    etoro.calls.clear

    result = nil
    each_close([ Date.new(2026, 10, 23) ]) { result = import_with(etoro) }

    assert_empty result.partial_failures
    assert_equal [ 4, 3 ], [ etoro.count(:raw), etoro.count("OneDay") ], "every read, and three checks before the others wait"
    assert_equal [ "2026-10-16" ] * 4, ids.map { |id| history(id)["checked"] }
    assert_equal [ "2026-10-23" ] * 4, ids.map { |id| history(id)["priced_through"] }
  end

  test "split checks eToro keeps failing to answer wait for the others, which are still made" do
    ids = (3001..3006).to_a
    ids.drop(1).each do |id|
      listing("SYM#{id}", "XNYS")
      describe(id, "SYM#{id}", exchange_id: 5)
    end
    hold(*ids.map { |id| position(id, id, opened: "2026-06-01T14:00:00Z") })
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 30))
    failing = ids.first(3)
    etoro = Class.new(FakeEtoro) do
      attr_accessor :failing_checks

      define_method(:fetch_adjusted_candles) do |instrument_id, interval:|
        raise Provider::Etoro::ApiError.new("eToro API error (status 500)", status_code: 500) if Array(failing_checks).include?(instrument_id)

        super(instrument_id, interval: interval)
      end
    end.new(symbols: ids.to_h { |id| [ id, "SYM#{id}/USD" ] }, prices: ids.to_h { |id| [ id, prices ] })
    each_close([ Date.new(2026, 10, 9) ]) { import_with(etoro) }
    etoro.failing_checks = failing

    each_close(Date.new(2026, 10, 12)..Date.new(2026, 10, 30)) { import_with(etoro) }

    assert_equal ids - failing, ids.select { |id| history(id)["checked"] > "2026-10-09" }
  end

  test "a rate limit on a split check leaves the rest of the price history to the next sync" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })
    each_close([ Date.new(2026, 10, 16) ]) { import_with(etoro) }
    etoro.adjusted_failure = Provider::Etoro::RateLimitError.new("eToro rate limit exceeded.", status_code: 429)
    etoro.calls.clear

    result = nil
    each_close([ Date.new(2026, 10, 23) ]) { result = import_with(etoro) }

    assert_not_nil result.rate_limited_at
    assert_equal [ :price_history ], result.partial_failures.map { |failure| failure[:what] }
    assert_equal [ 1, 1 ], [ etoro.count(:raw), etoro.count("OneDay") ]
    assert_equal [ "2026-10-16", "2026-10-16" ], history(3001).values_at("checked", "priced_through")
  end

  test "a jump eToro's adjusted history does not explain is checked again for a week, then taken as a price move" do
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 30)) { |day| day < Date.new(2026, 10, 21) ? 100 : 50 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices })

    each_close(Date.new(2026, 10, 19)..Date.new(2026, 10, 30)) { import_with(etoro) }

    assert_equal 7, etoro.count("OneDay"), "the first sync and the six from the jump to a week after it"
    assert_equal 11, etoro.count(:raw), "one read a sync, and the jump's own day one more"
    assert_equal [ [], "2026-10-30" ], history(3001).values_at("splits", "through")
    assert_nil history(3001)["jump"]
    assert_equal every_day(prices, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 30)), stored_prices(@acme)
    assert DebugLogEntry.where(provider_key: "etoro").where("message LIKE ?", "%3001%split-adjusted history shows no split%").exists?
  end

  test "a restatement after the history was worked out values the days without a session anew" do
    @etoro_account.update!(current_balance: 2100, cash_balance: 100,
      raw_positions_payload: [ position(501, 3001, opened: "2026-09-01T14:00:00Z", units: 10, amount: 1000, pnl: 1000) ])
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD" }, prices: { 3001 => prices }, splits: { 3001 => { Date.new(2026, 10, 19) => 2 } })

    each_close([ Date.new(2026, 10, 16) ]) { sync_account(etoro) }
    # eToro restates the position on the new shares.
    @etoro_account.update!(raw_positions_payload: [ position(501, 3001, opened: "2026-09-01T14:00:00Z", units: 20, amount: 1000, pnl: 1000) ])
    each_close([ Date.new(2026, 10, 19) ]) { sync_account(etoro) }

    held = @account.holdings.where(security: @acme, date: Date.new(2026, 9, 1)..Date.new(2026, 10, 18)).order(:date).pluck(:date, :amount).to_h
    assert_equal (Date.new(2026, 9, 1)..Date.new(2026, 10, 18)).to_h { |day| [ day, BigDecimal("2000") ] }, held
  end

  test "a closed line of a security eToro prices through another line follows that line's splits" do
    describe(3002, "ACME.RTH", exchange_id: 33)
    close(trade(601, 3002, units: 5, investment: 500, opened: "2026-06-15T15:00:00Z", closed: "2026-07-15T15:00:00Z"))
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    splits = { Date.new(2026, 8, 3) => 2, Date.new(2026, 10, 21) => 3 }
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD", 3002 => "ACME.RTH/USD" }, prices: { 3001 => prices, 3002 => prices }, splits: { 3001 => splits, 3002 => splits })
    sell = -> { @account.entries.find_by!(external_id: "etoro_position_601_close_#{Time.utc(2026, 7, 15, 15).to_i}").trade.qty }

    each_close([ Date.new(2026, 10, 16) ]) { sync_trades(etoro) }
    assert_equal BigDecimal("-10"), sell.call
    each_close([ Date.new(2026, 10, 21) ]) { sync_trades(etoro) }

    assert_equal BigDecimal("-30"), sell.call
  end

  test "a close on the day eToro's prices switch, before the switch, of a security a provider prices goes on today's shares" do
    provided = listing("PRVD", nil, offline: false)
    provided.update_columns(price_provider: "yahoo_finance")
    describe(3011, "PRVD")
    hold
    close(trade(601, 3011, units: 10, investment: 2000, opened: "2026-06-01T15:00:00Z", closed: "2026-08-07T15:00:00Z").merge("closeRate" => 200))
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23)) { 100 }
    etoro = FakeEtoro.new(symbols: { 3011 => "PRVD/USD" }, prices: { 3011 => prices }, splits: { 3011 => { Date.new(2026, 8, 7) => 2 } })

    each_close([ Date.new(2026, 10, 16) ]) { sync_trades(etoro) }

    assert_equal [ [ "2026-08-07", "2" ] ], split_list(history(3011))
    assert_equal BigDecimal("20"), @account.entries.find_by!(external_id: "etoro_position_601_open").trade.qty
    assert_equal BigDecimal("-20"), @account.entries.find_by!(external_id: "etoro_position_601_close_#{Time.utc(2026, 8, 7, 15).to_i}").trade.qty
  end

  test "the closed trades of a security a provider prices stay on the shares its stored prices are on" do
    as_traded = listing("PRVD", nil, offline: false)
    unpriced = listing("PRVE", nil, offline: false)
    [ as_traded, unpriced ].each { |security| security.update_columns(price_provider: "yahoo_finance") }
    describe(3011, "PRVD")
    describe(3012, "PRVE")
    hold
    close(
      trade(601, 3011, units: 10, investment: 440, opened: "2026-06-01T15:00:00Z", closed: "2026-07-01T15:00:00Z"),
      trade(602, 3012, units: 10, investment: 440, opened: "2026-06-01T15:00:00Z", closed: "2026-07-01T15:00:00Z")
    )
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    split = { Date.new(2026, 8, 3) => 2 }
    etoro = FakeEtoro.new(symbols: { 3011 => "PRVD/USD", 3012 => "PRVE/USD" }, prices: { 3011 => prices, 3012 => prices }, splits: { 3011 => split, 3012 => split })
    # The provider stored PRVD's prices before the split, on the shares of the time.
    prices.each { |day, price| Security::Price.create!(security: as_traded, date: day, price: price * 2, currency: "USD") if day.between?(Date.new(2026, 6, 1), Date.new(2026, 7, 31)) }
    sold = ->(position_id) { @account.entries.find_by!(external_id: "etoro_position_#{position_id}_close_#{Time.utc(2026, 7, 1, 15).to_i}").trade.qty }

    each_close([ Date.new(2026, 10, 16) ]) { sync_trades(etoro) }

    assert_equal BigDecimal("-10"), sold.call(601)
    assert_equal BigDecimal("-20"), sold.call(602)
  end

  test "eToro withholding its prices is reported and left for the next sync" do
    beta = listing("BETA", "XNYS")
    describe(3002, "BETA", exchange_id: 5)
    hold(position(501, 3001, opened: "2026-06-01T14:00:00Z"), position(502, 3002, opened: "2026-07-01T14:00:00Z"))
    @provider.expects(:fetch_daily_candles).twice
      .raises(Provider::Etoro::TransientError.new("eToro withheld its market data (status 403)", status_code: 403))

    result = import

    assert_equal [ I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: 2) ], result.partial_failures.map { |failure| failure[:message] }
    assert_empty Security::Price.where(security: [ @acme, beta ])
    assert_nil history(3001)["through"]
    assert_nil result.rate_limited_at
  end

  test "an instrument eToro keeps failing on is asked after the others, which go on" do
    beta = listing("BETA", "XNYS")
    gamma = listing("GAMA", "XNYS")
    describe(3002, "BETA", exchange_id: 5)
    describe(3003, "GAMA", exchange_id: 5)
    hold(position(501, 3001, opened: "2026-06-01T14:00:00Z"), position(502, 3002, opened: "2026-07-01T14:00:00Z"), position(503, 3003, opened: "2026-08-03T14:00:00Z"))
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    unavailable = Provider::Etoro::TransientError.new("eToro API unavailable (status 503)", status_code: 503)
    etoro = FakeEtoro.new(symbols: { 3001 => "ACME/USD", 3002 => "BETA/USD", 3003 => "GAMA/USD" }, prices: { 3001 => prices, 3002 => prices, 3003 => prices }, failing: { 3001 => unavailable })

    result = nil
    each_close([ Date.new(2026, 10, 22) ]) { result = import_with(etoro) }
    assert_equal [ I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: 1) ], result.partial_failures.map { |failure| failure[:message] }
    assert_equal [ Date.new(2026, 10, 22) ] * 2, [ beta, gamma ].map { |security| security.prices.maximum(:date) }

    etoro.calls.clear
    each_close([ Date.new(2026, 10, 23) ]) { import_with(etoro) }

    assert_equal [ 3002, 3003, 3001 ], etoro.calls.select { |kind, _| kind == :raw }.map(&:last)
    assert_equal [ Date.new(2026, 10, 23) ] * 2, [ beta, gamma ].map { |security| security.prices.maximum(:date) }
  end

  test "eToro failing on several instruments in a row leaves the rest for the next sync" do
    ids = 3001..3004
    ids.drop(1).each do |id|
      listing("SYM#{id}", "XNYS")
      describe(id, "SYM#{id}", exchange_id: 5)
    end
    hold(*ids.map { |id| position(id, id, opened: "2026-06-01T14:00:00Z") })
    prices = prices_between(Date.new(2026, 3, 2), Date.new(2026, 10, 23))
    unavailable = Provider::Etoro::TransientError.new("eToro API unavailable (status 503)", status_code: 503)
    etoro = FakeEtoro.new(symbols: ids.to_h { |id| [ id, "SYM#{id}/USD" ] }, prices: ids.to_h { |id| [ id, prices ] }, failing: ids.to_h { |id| [ id, unavailable ] })

    result = import_with(etoro)

    assert_equal 3, etoro.count(:raw)
    assert_equal [ "eToro API unavailable (status 503)", I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: 3) ],
      result.partial_failures.map { |failure| failure[:message] }
  end

  test "a key eToro's price endpoints reject is reported and stops the fetch" do
    beta = listing("BETA", "XNYS")
    describe(3002, "BETA", exchange_id: 5)
    hold(position(501, 3001, opened: "2026-06-01T14:00:00Z"), position(502, 3002, opened: "2026-07-01T14:00:00Z"))
    @provider.expects(:fetch_daily_candles).once
      .raises(Provider::Etoro::AuthenticationError, "eToro authentication failed (401). Check your API key and user key.")

    result = import

    assert_equal [ "eToro authentication failed (401). Check your API key and user key." ], result.partial_failures.map { |failure| failure[:message] }
    assert_empty Security::Price.where(security: [ @acme, beta ])
  end

  test "an instrument eToro sends no prices for is reported, and the others go on" do
    beta = listing("BETA", "XNYS")
    describe(3002, "BETA", exchange_id: 5)
    hold(position(501, 3001, opened: "2026-06-01T14:00:00Z"), position(502, 3002, opened: "2026-10-01T14:00:00Z"))
    @provider.expects(:fetch_daily_candles).with(3001, from: Date.new(2026, 5, 24))
      .raises(Provider::Etoro::ApiError.new("eToro API error (status 404)", status_code: 404))
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3002, from: Date.new(2026, 9, 23), closes: adjusted)
    expect_adjusted(3002, "OneDay", adjusted)

    result = import

    assert_equal [ I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: 1) ], result.partial_failures.map { |failure| failure[:message] }
    assert_empty @acme.prices
    assert_equal every_day(adjusted, from: Date.new(2026, 10, 1), through: Date.new(2026, 10, 23)), stored_prices(beta)
    assert_nil @acme.reload.offline_reason, "a security eToro has not priced is left to Sure's health checks"
    assert_equal OFFLINE_REASON, beta.reload.offline_reason
  end

  test "a rate limit leaves the rest of the price history to the next sync" do
    @provider.expects(:fetch_daily_candles).raises(Provider::Etoro::RateLimitError.new("eToro rate limit exceeded.", status_code: 429))

    result = import

    assert_equal Time.current, result.rate_limited_at
    assert_equal [ :price_history ], result.partial_failures.map { |failure| failure[:what] }
  end

  test "stops at the request budget and fetches the rest on the next sync" do
    EtoroItem::PriceHistoryImporter.stubs(:max_requests_per_sync).returns(2)
    beta = listing("BETA", "XNYS")
    describe(3002, "BETA", exchange_id: 5)
    hold(position(501, 3001, opened: "2026-06-01T14:00:00Z"), position(502, 3002, opened: "2026-10-01T14:00:00Z"))
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: adjusted)
    expect_adjusted(3001, "OneDay", adjusted)

    result = import

    assert_equal [ I18n.t("etoro_items.sync.partial_failures.price_history_incomplete", count: 1) ], result.partial_failures.map { |failure| failure[:message] }
    assert_empty beta.prices

    expect_raw(3002, from: Date.new(2026, 9, 23), closes: adjusted)
    expect_adjusted(3002, "OneDay", adjusted)

    assert_empty import.partial_failures
    assert_equal every_day(adjusted, from: Date.new(2026, 10, 1), through: Date.new(2026, 10, 23)), stored_prices(beta)
  end

  test "reads eToro's weekly history only when the history needed predates its daily one" do
    hold(position(501, 3001, opened: "2022-03-01T15:00:00Z"))
    split_on = Date.new(2022, 6, 15)
    adjusted = prices_between(Date.new(2022, 2, 14), Date.new(2026, 10, 23))
    daily = adjusted.select { |day, _| day >= Date.new(2022, 10, 3) }
    expect_raw(3001, from: Date.new(2022, 2, 21), closes: restate(adjusted, from: Date.new(2022, 2, 22), splits: { split_on => 3 }))
    expect_adjusted(3001, "OneDay", daily)
    expect_adjusted(3001, "OneWeek", adjusted.group_by { |day, _| day.beginning_of_week }.transform_values { |days| days.max_by(&:first).last }, weekly: true)

    import

    assert_equal [ [ "2022-06-15", "3" ] ], split_list(history(3001))
    assert_equal adjusted.values_at(Date.new(2022, 6, 14), Date.new(2022, 6, 15)), stored_prices(@acme).values_at(Date.new(2022, 6, 14), Date.new(2022, 6, 15))
  end

  test "a first read eToro sends none of the split-adjusted weeks it needs is left for the next sync" do
    hold(position(501, 3001, opened: "2022-03-01T15:00:00Z"))
    adjusted = prices_between(Date.new(2022, 2, 14), Date.new(2026, 10, 23))
    raw = restate(adjusted, from: Date.new(2022, 2, 22), splits: { Date.new(2022, 6, 15) => 3 })
    daily = adjusted.select { |day, _| day >= Date.new(2022, 10, 3) }
    expect_raw(3001, from: Date.new(2022, 2, 21), closes: raw)
    expect_adjusted(3001, "OneDay", daily)
    expect_adjusted(3001, "OneWeek", {}, weekly: true)

    result = import

    assert_empty @acme.prices
    assert_nil history(3001)["splits"]
    assert_equal [ I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: 1) ], result.partial_failures.map { |failure| failure[:message] }

    expect_raw(3001, from: Date.new(2022, 2, 21), closes: raw)
    expect_adjusted(3001, "OneDay", daily)
    expect_adjusted(3001, "OneWeek", adjusted.group_by { |day, _| day.beginning_of_week }.transform_values { |days| days.max_by(&:first).last }, weekly: true)
    import

    assert_equal [ [ "2022-06-15", "3" ] ], split_list(history(3001))
    assert_equal every_day(adjusted, from: Date.new(2022, 3, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "a jump eToro sends no split-adjusted days for keeps the splits and prices found before until it does" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "200", price: 200)
    instruments = @item.reload.instruments_map.deep_dup
    instruments["3001"]["price_history"]["splits"] = [ [ "2026-08-12", "5/4", "200" ] ] # a bonus issue an earlier check found
    @item.update!(raw_instruments_payload: instruments)
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23)) { 100 }
    raw = restate(adjusted, from: Date.new(2026, 5, 25), splits: { Date.new(2026, 8, 12) => Rational(5, 4), Date.new(2026, 10, 22) => 2 })
    expect_raw(3001, from: Date.new(2026, 10, 20), closes: raw)
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: raw)
    expect_adjusted(3001, "OneDay", {})
    @provider.expects(:fetch_adjusted_candles).with(3001, interval: "OneWeek").never # its weeks cannot tell a bonus issue from a move

    result = import

    assert_equal [ [ "2026-08-12", "5/4" ] ], split_list(history(3001))
    assert_equal({ Date.new(2026, 10, 20) => BigDecimal("200"), Date.new(2026, 10, 21) => BigDecimal("200") }, stored_prices(@acme))
    assert_equal [ I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: 1) ], result.partial_failures.map { |failure| failure[:message] }

    expect_raw(3001, from: Date.new(2026, 10, 20), closes: raw)
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: raw)
    expect_adjusted(3001, "OneDay", adjusted)
    import

    assert_equal [ [ "2026-08-12", "5/4" ], [ "2026-10-22", "2" ] ], split_list(history(3001))
    assert_equal every_day(adjusted, from: Date.new(2026, 6, 1), through: Date.new(2026, 10, 23)), stored_prices(@acme)
  end

  test "the trades of a security a provider prices get their splits, but no prices from eToro" do
    online = listing("ONLN", nil, offline: false)
    describe(3011, "ONLN")
    hold
    close(trade(601, 3011, opened: "2026-03-02T15:00:00Z", closed: "2026-05-01T15:00:00Z"))
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3011, from: Date.new(2026, 4, 23), closes: restate(adjusted, from: Date.new(2026, 4, 24), splits: { Date.new(2026, 7, 1) => 2 }))
    expect_adjusted(3011, "OneDay", adjusted)

    import
    travel_to Time.utc(2026, 10, 28, 12)
    import

    assert_empty online.prices
    assert_equal [ [ "2026-07-01", "2" ] ], split_list(history(3011))
    assert_nil history(3011)["security_id"]
  end

  test "crypto is priced on every day of the week without a split check" do
    Onchain::SecurityResolver.stubs(:resolve).returns(nil)
    describe(3005, "ABCCOIN", type_id: 10)
    hold(position(505, 3005, opened: "2026-10-18T10:00:00Z"))
    days = (Date.new(2026, 10, 18)..Date.new(2026, 10, 24)).to_a
    expect_raw(3005, from: Date.new(2026, 10, 17), symbol: "ABCCOIN/USD", closes: days.to_h { |day| [ day, BigDecimal("2.5") ] })
    @provider.expects(:fetch_adjusted_candles).never

    import

    coin = Security.find_by!(ticker: "ETORO:3005")
    assert_equal days.first(6), stored_prices(coin).keys, "Saturday's session is still open"
    assert_equal OFFLINE_REASON, coin.reload.offline_reason
  end

  test "a sync stopped after storing prices has claimed them, so a later sync takes them back" do
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23))
    expect_raw(3001, from: Date.new(2026, 5, 24), closes: adjusted)
    expect_adjusted(3001, "OneDay", adjusted)
    # The worker stops right after the prices are written.
    EtoroItem::PriceHistoryImporter.any_instance.stubs(:updated_history).raises(Interrupt)

    assert_raises(Interrupt) { import }
    assert @acme.prices.none? || history(3001)&.dig("written_from"), "prices stored are recorded as eToro's"

    EtoroItem::PriceHistoryImporter.any_instance.unstub(:updated_history)
    accounts(:investment).holdings.create!(security: @acme, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    import

    assert_empty @acme.prices
    assert_nil @acme.reload.offline_reason
  end

  test "unlinking the account hands its securities back at once, without a sync" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "100")

    @account.account_providers.reload.destroy_all

    assert_nil @acme.reload.offline_reason
    assert_empty @acme.prices
    assert_nil history(3001)["security_id"]
  end

  test "an account disabled hands its securities back on the next sync, even one eToro refuses" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "100")
    @account.disable!
    @provider.expects(:fetch_balances).raises(Provider::Etoro::AuthenticationError, "eToro authentication failed (401).")

    assert_raises(Provider::Etoro::AuthenticationError) { EtoroItem::Importer.new(@item.reload, provider: @provider).import }

    assert_nil @acme.reload.offline_reason
    assert_empty @acme.prices
  end

  test "an account not linked to Sure fetches no prices and hands its securities back without eToro's prices" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "100")
    @acme.update!(offline_reason: OFFLINE_REASON)
    @etoro_account.account_provider.destroy!

    assert_empty import.partial_failures
    assert_nil @acme.reload.offline_reason
    assert_empty @acme.prices
  end

  test "an account shown by its totals fetches no prices and hands its securities back without eToro's prices" do
    seed_history(3001, through: Date.new(2026, 10, 21), close: "100")
    @acme.update!(offline_reason: OFFLINE_REASON)
    @etoro_account.update!(display_mode: :totals)

    assert_empty import.partial_failures
    assert_nil @acme.reload.offline_reason
    assert_empty @acme.prices
    assert_nil history(3001)["security_id"]
  end

  test "the holdings history values a split day at eToro's adjusted prices" do
    @etoro_account.update!(
      current_balance: 1500,
      cash_balance: 300,
      raw_positions_payload: [ position(501, 3001, opened: "2026-09-01T14:00:00Z", units: 10, amount: 1000, pnl: 200) ],
      raw_trades_payload: [ trade(501, 3001, units: 3, investment: 600, net_profit: 30, opened: "2026-09-01T14:00:00Z", closed: "2026-09-15T15:00:00Z") ]
    )
    adjusted = prices_between(Date.new(2026, 1, 5), Date.new(2026, 10, 23)) do |day|
      if day < Date.new(2026, 9, 15) then 100
      elsif day < Date.new(2026, 10, 1) then 105
      elsif day < Date.new(2026, 10, 15) then 110
      else 120
      end
    end
    expect_raw(3001, from: Date.new(2026, 8, 24), closes: restate(adjusted, from: Date.new(2026, 8, 25), splits: { Date.new(2026, 10, 1) => 2 }))
    expect_adjusted(3001, "OneDay", adjusted)

    import
    EtoroAccount::Processor.new(@etoro_account.reload).process
    Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances

    buy = @account.entries.find_by!(external_id: "etoro_position_501_open")
    assert_equal [ BigDecimal("16"), BigDecimal("1600") ], [ buy.trade.qty, buy.amount ]
    expected = {
      Date.new(2026, 9, 14) => [ BigDecimal("16"), BigDecimal("1600") ],
      Date.new(2026, 9, 15) => [ BigDecimal("10"), BigDecimal("1050") ],
      Date.new(2026, 9, 30) => [ BigDecimal("10"), BigDecimal("1050") ],
      Date.new(2026, 10, 1) => [ BigDecimal("10"), BigDecimal("1100") ],
      Date.new(2026, 10, 23) => [ BigDecimal("10"), BigDecimal("1200") ]
    }
    assert_equal expected, expected.keys.to_h { |day| [ day, @account.holdings.where(security: @acme, date: day).pick(:qty, :amount) ] }
    assert_equal expected.transform_values(&:last), expected.keys.to_h { |day| [ day, @account.balances.find_by!(date: day).end_non_cash_balance ] }
  end

  private

    def import
      import_with(@provider)
    end

    def import_with(provider)
      EtoroItem::PriceHistoryImporter.new(@item.reload, @etoro_account.reload, provider: provider).import
    end

    # The price history, then what the account sync does with it.
    def sync_trades(provider)
      import_with(provider)
      EtoroAccount::Processor.new(@etoro_account.reload).process
    end

    def sync_account(provider)
      sync_trades(provider)
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    # At 18:00 New York time on each weekday of `days`, once its session
    # has closed.
    def each_close(days)
      days.select(&:on_weekday?).each do |day|
        travel_to NEW_YORK.local(day.year, day.month, day.day, 18)
        yield day
      end
    end

    def listing(ticker, mic, **attributes)
      security = Security.create!({ ticker: ticker, name: ticker.titleize, exchange_operating_mic: mic, offline: true }.merge(attributes))
      resolver = mic ? Security::Resolver.stubs(:new).with(ticker, exchange_operating_mic: mic) : Security::Resolver.stubs(:new).with(ticker)
      resolver.returns(stub(resolve: security))
      security
    end

    def describe(instrument_id, symbol, type_id: 5, exchange_id: nil)
      instruments = @item.reload.instruments_map.deep_dup
      instruments[instrument_id.to_s] = { "symbol" => symbol, "name" => symbol.titleize, "type_id" => type_id, "exchange_id" => exchange_id }.compact
      @item.update!(raw_instruments_payload: instruments)
    end

    def hold(*positions)
      @etoro_account.update!(raw_positions_payload: positions)
    end

    def close(*trades)
      @etoro_account.update!(raw_trades_payload: trades)
    end

    def position(id, instrument_id, opened:, units: 1, amount: 100, pnl: 0)
      {
        "positionID" => id, "instrumentID" => instrument_id, "isBuy" => true, "leverage" => 1, "settlementTypeID" => 1,
        "units" => units, "amount" => amount, "unitsBaseValueDollars" => amount, "openDateTime" => opened, "unrealizedPnL" => { "pnL" => pnl }
      }
    end

    def trade(id, instrument_id, opened:, closed:, units: 1, investment: 100, net_profit: 0)
      {
        "positionId" => id, "instrumentId" => instrument_id, "isBuy" => true, "leverage" => 1,
        "units" => units, "investment" => investment, "netProfit" => net_profit, "openTimestamp" => opened, "closeTimestamp" => closed
      }
    end

    # Round prices on the weekdays between two dates, on today's shares.
    def prices_between(from, to)
      (from..to).select(&:on_weekday?).to_h { |day| [ day, BigDecimal(block_given? ? yield(day) : 100 + day.jd % 5) ] }
    end

    # The closes as eToro traded them: before each split, in the shares of the time.
    def restate(adjusted, from:, splits:)
      adjusted.select { |day, _| day >= from }.to_h do |day, price|
        [ day, splits.reduce(price) { |raw, (split_on, ratio)| day < split_on ? raw * ratio : raw } ]
      end
    end

    # Every calendar day from `from` through `through` at the latest close
    # on or before it.
    def every_day(closes, from:, through:)
      sorted = closes.sort.to_h
      latest = nil
      (sorted.keys.first..through).each_with_object({}) do |day, prices|
        latest = sorted.fetch(day, latest)
        prices[day] = latest if day >= from
      end
    end

    # eToro's date-range candles opening from `from` on, as it filters them:
    # a session's candle opens at 17:00 New York time the evening before it.
    def expect_raw(instrument_id, from:, closes:, symbol: nil)
      symbol ||= "#{@item.instruments_map.dig(instrument_id.to_s, "symbol")}/USD"
      candles = closes.sort.reverse.filter_map do |day, close|
        opened = NEW_YORK.local(day.year, day.month, day.day, 17) - 1.day
        next if opened < from.in_time_zone("UTC")

        { "time" => opened.utc.iso8601, "open" => close.to_s, "high" => close.to_s, "low" => close.to_s, "close" => close.to_s, "volume" => "1000" }
      end
      @provider.expects(:fetch_daily_candles).with(instrument_id, from: from).returns({ "symbol" => symbol, "results" => candles })
    end

    # eToro's split-adjusted candles: a day's is dated at midnight UTC, a
    # week's at 17:00 New York time the Sunday before it.
    def expect_adjusted(instrument_id, interval, closes, weekly: false)
      candles = closes.sort.reverse.map do |day, close|
        opened = weekly ? (NEW_YORK.local(day.year, day.month, day.day, 17) - 1.day).utc.iso8601 : "#{day.iso8601}T00:00:00Z"
        { "instrumentID" => instrument_id, "fromDate" => opened, "open" => close.to_f, "high" => close.to_f, "low" => close.to_f, "close" => close.to_f, "volume" => 1000.0 }
      end
      @provider.expects(:fetch_adjusted_candles).with(instrument_id, interval: interval).returns(candles)
    end

    # What a sync through `through` left: ACME's prices of its last two
    # sessions, and its split check.
    def seed_history(instrument_id, through:, close:, price: 100, checked: through)
      @acme.update!(offline_reason: OFFLINE_REASON)
      [ through - 1, through ].each { |day| Security::Price.create!(security: @acme, date: day, price: price, currency: "USD") }
      instruments = @item.reload.instruments_map.deep_dup
      instruments[instrument_id.to_s]["price_history"] = {
        "splits" => [], "from" => "2026-06-01", "checked" => checked.iso8601, "compared" => checked.iso8601, "through" => through.iso8601, "close" => close,
        "security_id" => @acme.id, "currency" => "USD", "written_from" => "2026-06-01", "priced_from" => "2026-06-01", "priced_through" => through.iso8601
      }
      @item.update!(raw_instruments_payload: instruments)
    end

    def history(instrument_id)
      @item.reload.instruments_map.dig(instrument_id.to_s, "price_history")
    end

    # The splits found, by the first day on the new shares and the ratio.
    def split_list(history)
      Array(history["splits"]).map { |split| split.first(2) }
    end

    def stored_prices(security)
      security.prices.order(:date).pluck(:date, :price).to_h
    end
end
