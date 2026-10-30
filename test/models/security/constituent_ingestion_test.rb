require "test_helper"

# How a fund's holdings get from the provider into `security_constituents`.
#
# The load-bearing tests are the skip gate, because it decides whether the
# provider call happens at all and so is the whole cost of the feature, and the
# capability check, because without it the gate either never closes or closes
# against the one provider that could answer.
class Security::ConstituentIngestionTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
    # Metadata present from the outset. `import_provider_details` refetches for
    # METADATA reasons when a name plus a logo or website is missing, and the
    # fixture has neither -- so without this the provider is called again for a
    # reason that has nothing to do with the constituents gate, and these tests
    # would be asserting the wrong thing.
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")
  end

  # --------------------------------------------------------------- the gate

  test "a fund is asked once, and not asked again" do
    assert_nil @security.constituents_fetched_at

    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).once.returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_constituents: true)
    assert_equal 1, @security.reload.constituents.count

    second = capable_provider("provider")
    second.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(second)
    @security.import_provider_details(include_constituents: true)
  end

  # The negative, and the reason the gate is keyed on a timestamp rather than on
  # "does it have constituents". Most securities are not funds, so the provider
  # returns nothing for them -- and under a presence-keyed gate every one of them
  # would be re-asked on every sync, for ever.
  test "a security the provider has no holdings for is also not asked again" do
    import(info(constituents: nil))

    assert_empty @security.reload.constituents
    assert_not_nil @security.constituents_fetched_at, "nothing recorded that we asked"

    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_constituents: true)
  end

  # A failed answer is not an answer. Stamping it would close the gate on a
  # fund whose holdings were never read; leaving it unstamped means the next
  # sync asks again, the same rule the classification record follows.
  test "a failed answer is not recorded, so the next sync asks again" do
    @security.constituents.create!(ticker: "MSFT", name: "Microsoft", weight: 10)
    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).twice.returns(
      provider_error_response(Provider::Error.new("fundamentals unavailable"))
    )
    @security.stubs(:price_data_provider).returns(provider)

    2.times { @security.import_provider_details(include_constituents: true) }

    assert_nil @security.reload.constituents_fetched_at
    assert_equal [ "MSFT" ], @security.constituents.pluck(:ticker), "a failed answer wiped the stored set"
  end

  # The importers walk every security on every sync, so a caller that has not
  # opted in must not inherit that cost -- the same reason
  # `include_classification:` defaults to false.
  test "a caller that has not opted in makes no provider call" do
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details

    assert_empty @security.reload.constituents
    assert_nil @security.constituents_fetched_at
  end

  # A fetch made for another reason (here a missing logo) carries the holdings
  # too, but a caller that did not ask for them must not have them stored or
  # stamped: that would close the gate on its behalf.
  test "a caller that has not opted in stores nothing, even when it fetches" do
    @security.update!(logo_url: nil, website_url: nil)
    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).once.returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details

    assert_empty @security.reload.constituents
    assert_nil @security.constituents_fetched_at
  end

  test "re-importing a fund replaces its holdings rather than duplicating them" do
    import(info(constituents: [ constituent("MSFT", "Microsoft", 10), constituent("AAPL", "Apple", 5) ]))
    @security.update!(constituents_fetched_at: nil)

    import(info(constituents: [ constituent("MSFT", "Microsoft", 12) ]))

    assert_equal [ "MSFT" ], @security.reload.constituents.pluck(:ticker)
    assert_equal BigDecimal("12"), @security.constituents.sole.weight
  end

  # EODHD rounds `Assets_%`, so a position too small to round up to 0.01 comes
  # back as 0. The rows are written in one transaction, so a zero refused by a
  # validation would take the whole fund's holdings down with it.
  test "a negligible holding reported as zero does not lose the rest of the fund" do
    import(info(constituents: [
      constituent("MSFT", "Microsoft", 60.0),
      constituent("TINY", "Negligible Co", 0),
      constituent("NVDA", "Nvidia", 40.0)
    ]))

    assert_equal 3, @security.reload.constituents.count,
                 "a zero-weight holding aborted the whole import"
    assert_in_delta 0.6, @security.look_through_weights["MSFT"].to_f, 0.000001
  end

  # ----------------------------------------------------- provider capability

  # A security first synced under a provider that supplies no constituents must
  # not be stamped with an empty table, or the stamp closes the gate for ever
  # and configuring a capable provider later never fills it.
  # `price_data_provider` falls back to the first configured provider, so no
  # action on the security is needed to land in that state.
  #
  # Asserts the DELTA: empty after the incapable sync, filled after the capable
  # one.
  test "a security synced under an incapable provider is filled when a capable one arrives" do
    incapable = capable_provider("incapable", constituents: false)
    incapable.stubs(:class).returns(Provider::TwelveData)
    incapable.stubs(:fetch_security_info).returns(provider_success_response(info(constituents: nil)))
    @security.stubs(:price_data_provider).returns(incapable)
    @security.import_provider_details(include_constituents: true)

    assert_empty @security.reload.constituents, "an incapable provider stored constituents"

    capable = capable_provider("capable")
    capable.stubs(:class).returns(Provider::Eodhd)
    capable.stubs(:fetch_security_info).returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(capable)
    @security.import_provider_details(include_constituents: true)

    assert_equal 1, @security.reload.constituents.count,
                 "a capable provider was never asked, because the incapable one had stamped the gate shut"
  end

  # The cost half of the same rule. Gating the STAMP rather than the ask would
  # leave the flag true on every sync, and `!wants_constituents` is a separate
  # AND-term that `has_metadata` cannot short-circuit -- so every provider that
  # cannot answer would re-fetch every security, for ever.
  test "an incapable provider is not asked at all" do
    incapable = capable_provider("incapable", constituents: false, classification: false)
    incapable.stubs(:class).returns(Provider::TwelveData)
    incapable.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(incapable)

    @security.import_provider_details(include_constituents: true)

    assert_nil @security.reload.constituents_fetched_at,
               "an incapable provider left a stamp, which would close the gate against a capable one"
  end

  # The second lock on the same door. `store_constituents` deletes before it
  # writes, so an incapable provider reaching it would wipe a set it was never
  # in a position to replace.
  test "an incapable provider cannot wipe a stored set" do
    import(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    assert_equal 1, @security.reload.constituents.count

    incapable = capable_provider("incapable", constituents: false)
    @security.stubs(:price_data_provider).returns(incapable)
    @security.send(:store_constituents, nil)

    assert_equal 1, @security.reload.constituents.count,
                 "an incapable provider emptied the table and stamped the emptiness as fact"
  end

  # A world tracker reports thousands of holdings, and this runs inside the
  # account sync. Per-row `destroy`/`create!` cost a DELETE per stored row and
  # a uniqueness SELECT plus an INSERT per new one; the write is now one DELETE
  # and one INSERT, so the statement count does not grow with the list.
  test "replacing a fund's holdings costs the same statements for a long list as a short one" do
    provider = capable_provider("provider")
    @security.stubs(:price_data_provider).returns(provider)

    short = [ constituent("AAA", "A", 60), constituent("BBB", "B", 40) ]
    long = (1..50).map { |i| constituent("T#{i}", "Holding #{i}", 2) }

    @security.send(:store_constituents, long)
    short_count = sql_statements { @security.send(:store_constituents, short) }
    @security.send(:store_constituents, short)
    long_count = sql_statements { @security.send(:store_constituents, long) }

    assert_equal short_count, long_count, "the write grows with the number of holdings"
    assert_equal 50, @security.reload.constituents.count
    assert_equal BigDecimal("2"), @security.constituents.find_by!(ticker: "T7").weight
    assert_equal "Holding 7", @security.constituents.find_by!(ticker: "T7").name
  end

  # Securities are shared across families, so two syncs can replace the same
  # fund at once. Neither DELETE sees the other's uncommitted rows, and the
  # second INSERT then breaks the unique (security_id, ticker) index. Locking
  # the security's row first makes the second wait and replace the first's set.
  test "replacing a fund's holdings locks the security before deleting the old set" do
    provider = capable_provider("provider")
    @security.stubs(:price_data_provider).returns(provider)

    statements = []
    recorder = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(recorder, "sql.active_record") do
      @security.send(:store_constituents, [ constituent("AAA", "A", 100) ])
    end

    lock = statements.index { |sql| sql.match?(/\ASELECT .*"securities".* FOR UPDATE/m) }
    delete = statements.index { |sql| sql.match?(/\ADELETE FROM "security_constituents"/) }

    assert lock, "the security's row is never locked"
    assert_operator lock, :<, delete, "the lock is taken after the old set is deleted"
  end

  # -------------------------------------------------------- malformed lists
  #
  # One row the table refuses would raise out of `store_constituents`, roll
  # the fund back unstamped, and stop both market data importers at that fund
  # on every run. Each shape below raised before the fix, so the stamp and row
  # count are the assertions that fail without it.

  test "a duplicated ticker keeps its first occurrence and stores the rest" do
    assert_difference -> { holdings_log_count }, 1 do
      import(info(constituents: [
        constituent("AAA", "First", 5),
        constituent("AAA", "Second", 3),
        constituent("BBB", "Other", 2)
      ]))
    end

    assert_not_nil @security.reload.constituents_fetched_at, "the fund was left unstamped"
    assert_equal %w[AAA BBB], @security.constituents.order(:ticker).pluck(:ticker)
    assert_equal BigDecimal("5"), @security.constituents.find_by!(ticker: "AAA").weight,
                 "the second occurrence replaced the first"
    assert_equal "duplicate_ticker", last_holdings_log.metadata["reason"]
  end

  test "a negative weight skips that row and stores the rest" do
    assert_difference -> { holdings_log_count }, 1 do
      import(info(constituents: [ constituent("AAA", "Short", -1), constituent("BBB", "Other", 2) ]))
    end

    assert_not_nil @security.reload.constituents_fetched_at, "the fund was left unstamped"
    assert_equal %w[BBB], @security.constituents.pluck(:ticker)
    assert_equal "negative_weight", last_holdings_log.metadata["reason"]
  end

  test "a non-numeric weight skips that row and stores the rest" do
    assert_difference -> { holdings_log_count }, 1 do
      import(info(constituents: [ constituent("AAA", "Unknown", "n/a"), constituent("BBB", "Other", 2) ]))
    end

    assert_not_nil @security.reload.constituents_fetched_at, "the fund was left unstamped"
    assert_equal %w[BBB], @security.constituents.pluck(:ticker)
    assert_equal "non_numeric_weight", last_holdings_log.metadata["reason"]
  end

  test "a blank ticker skips that row and stores the rest" do
    [ nil, "", "  " ].each do |blank|
      @security.update_columns(constituents_fetched_at: nil)

      assert_difference -> { holdings_log_count }, 1, "for ticker #{blank.inspect}" do
        import(info(constituents: [ constituent(blank, "Nameless", 4), constituent("BBB", "Other", 2) ]))
      end

      assert_not_nil @security.reload.constituents_fetched_at, "unstamped for ticker #{blank.inspect}"
      assert_equal %w[BBB], @security.constituents.pluck(:ticker), "for ticker #{blank.inspect}"
      assert_equal "blank_ticker", last_holdings_log.metadata["reason"]
    end
  end

  # `BigDecimal("NaN")` and `BigDecimal("Infinity")` do not raise, so a rescue
  # alone let them through to `create!` (NaN fails `>= 0`) or to the column
  # (Infinity overflows it), and either rolled the fund back unstamped.
  test "a non-finite weight skips that row and stores the rest" do
    [ "NaN", "Infinity", "-Infinity" ].each do |weight|
      @security.update_columns(constituents_fetched_at: nil)

      assert_difference -> { holdings_log_count }, 1, "for weight #{weight}" do
        import(info(constituents: [ constituent("AAA", "Odd", weight), constituent("BBB", "Other", 2) ]))
      end

      assert_not_nil @security.reload.constituents_fetched_at, "unstamped for weight #{weight}"
      assert_equal %w[BBB], @security.constituents.pluck(:ticker), "for weight #{weight}"
      assert_equal "non_numeric_weight", last_holdings_log.metadata["reason"]
    end
  end

  # `weight` is numeric(9,6), so 1000 passes the model and is refused by
  # Postgres. Both sides of the boundary are pinned, and the largest value the
  # column holds is still stored.
  test "a weight the column cannot hold skips that row and stores the rest" do
    [ 1000, "1e3", "999.9999995" ].each do |weight|
      @security.update_columns(constituents_fetched_at: nil)

      assert_difference -> { holdings_log_count }, 1, "for weight #{weight}" do
        import(info(constituents: [ constituent("AAA", "Huge", weight), constituent("BBB", "Other", 2) ]))
      end

      assert_not_nil @security.reload.constituents_fetched_at, "unstamped for weight #{weight}"
      assert_equal %w[BBB], @security.constituents.pluck(:ticker), "for weight #{weight}"
      assert_equal "out_of_range_weight", last_holdings_log.metadata["reason"]
    end

    @security.update_columns(constituents_fetched_at: nil)
    assert_no_difference -> { holdings_log_count } do
      import(info(constituents: [ constituent("AAA", "Largest", "999.999999") ]))
    end
    assert_equal BigDecimal("999.999999"), @security.reload.constituents.find_by!(ticker: "AAA").weight
  end

  test "an entry that is not a hash skips that entry and stores the rest" do
    assert_difference -> { holdings_log_count }, 1 do
      import(info(constituents: [ "AAA", constituent("BBB", "Other", 2) ]))
    end

    assert_not_nil @security.reload.constituents_fetched_at, "the fund was left unstamped"
    assert_equal %w[BBB], @security.constituents.pluck(:ticker)
    assert_equal "malformed_entry", last_holdings_log.metadata["reason"]
    assert_equal "AAA", last_holdings_log.metadata["entry"]
  end

  test "a padded name is stored stripped" do
    import(info(constituents: [ constituent("AAA", "  Padded Inc  ", 5) ]))

    assert_equal "Padded Inc", @security.reload.constituents.find_by!(ticker: "AAA").name
  end

  # Duplicates are compared as the uniqueness validation compares them: after
  # the strip, and case-sensitively. `securities` compares tickers without
  # case, so a reader resolving these rows to securities sees `AAA` and `aaa`
  # as one instrument; merging them is that reader's decision, not storage's.
  test "a padded ticker is stored stripped, and tickers differing in case are both kept" do
    assert_no_difference -> { holdings_log_count } do
      import(info(constituents: [ constituent(" AAA ", "Padded", 5), constituent("aaa", "Lower", 3) ]))
    end

    assert_equal %w[AAA aaa], @security.reload.constituents.order(:weight).reverse.map(&:ticker)
  end

  test "the skipped row is logged with the fund, its ticker and the raw entry" do
    import(info(constituents: [ constituent("AAA", "Short", -1) ]))

    log = last_holdings_log
    assert_equal "warn", log.level
    assert_equal @security.id, log.metadata["security_id"]
    assert_equal @security.ticker, log.metadata["security_ticker"]
    assert_equal "AAA", log.metadata["ticker"]
    assert_equal({ "ticker" => "AAA", "name" => "Short", "weight" => -1 }, log.metadata["entry"])
  end

  test "a clean list writes no holdings log" do
    assert_no_difference -> { holdings_log_count } do
      import(info(constituents: [ constituent("AAA", "One", 5), constituent("BBB", "Two", 0) ]))
    end
    assert_equal 2, @security.reload.constituents.count
  end

  test "an empty list stamps, stores nothing and logs nothing" do
    assert_no_difference -> { holdings_log_count } do
      import(info(constituents: []))
    end
    assert_empty @security.reload.constituents
    assert_not_nil @security.constituents_fetched_at
  end

  test "an incapable provider handed a malformed list writes nothing" do
    incapable = capable_provider("incapable", constituents: false)
    @security.stubs(:price_data_provider).returns(incapable)

    assert_no_difference -> { holdings_log_count } do
      @security.send(:store_constituents, [ constituent("AAA", "Short", -1), constituent("BBB", "Other", 2) ])
    end
    assert_empty @security.reload.constituents
    assert_nil @security.constituents_fetched_at
  end

  private
    def sql_statements(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/i) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    def holdings_log_count
      DebugLogEntry.where(category: "security_holdings").count
    end

    def last_holdings_log
      DebugLogEntry.where(category: "security_holdings").order(:created_at, :id).last
    end

    def constituent(ticker, name, weight)
      { ticker: ticker, name: name, weight: weight }
    end

    def info(constituents:)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: nil, exchange_operating_mic: "XNAS", constituents: constituents
      )
    end

    def import(data)
      provider = capable_provider("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(data))
      @security.stubs(:price_data_provider).returns(provider)
      @security.import_provider_details(include_constituents: true)
    end
end
