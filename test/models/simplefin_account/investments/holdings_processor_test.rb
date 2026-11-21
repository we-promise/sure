require "test_helper"

class SimplefinAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)
  end

  test "cost_basis source is used unchanged as per share basis" do
    payload = {
      "cost_basis" => "16.61",
      "total_cost" => "9588.61",
      "value" => "10108.16"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("16.61"), cost_basis
    assert_equal "cost_basis", source_key
  end

  test "basis source is used unchanged as per share basis" do
    payload = {
      "basis" => "16.61",
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("16.61"), cost_basis
    assert_equal "basis", source_key
  end

  test "total_cost source is normalized to per share basis" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("9588.61") / BigDecimal("577.279"), cost_basis
    assert_equal "total_cost", source_key
  end

  test "value source is normalized to per share basis" do
    payload = {
      "value" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("9588.61") / BigDecimal("577.279"), cost_basis
    assert_equal "value", source_key
  end

  test "total cost source with zero quantity returns nil" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("0"), source_key)

    assert_nil cost_basis
    assert_equal "total_cost", source_key
  end

  test "total cost source with nil quantity returns nil" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, nil, source_key)

    assert_nil cost_basis
    assert_equal "total_cost", source_key
  end

  test "cost_basis from a known total-basis institution is divided by qty" do
    # Issue #1718 / #1182: Vanguard populates cost_basis with the total
    # position cost. When the institution is on the allowlist we divide.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("22004.40"),
      BigDecimal("139.00"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 158.30, cost_basis.to_f, 0.01
  end

  test "basis from a known total-basis institution is divided by qty" do
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("9000.00"),
      BigDecimal("200"),
      "basis",
      true
    )

    assert_equal BigDecimal("45.00"), cost_basis
  end

  test "cost_basis from a compliant institution is kept untouched (no false divide)" do
    # Codex regression: a legitimate per-share basis on a holding with a
    # large unrealized loss (e.g. $100/share basis now worth $5/share) must
    # NOT be divided by qty. Per the SimpleFIN spec, cost_basis is per-share
    # — only the institution allowlist should override that.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("100.00"),
      BigDecimal("100"),
      "cost_basis",
      false
    )

    assert_equal BigDecimal("100.00"), cost_basis
  end

  test "institution_reports_total_basis? matches Vanguard, Fidelity, Schwab, and E*Trade org metadata" do
    cases = {
      { "name" => "Vanguard" }                          => true,
      { "name" => "VANGUARD BROKERAGE" }                => true,
      { "name" => "Fidelity Investments" }              => true,
      { "domain" => "vanguard.com" }                    => true,
      { "domain" => "401k.fidelity.com" }               => true,
      { "name" => "Charles Schwab", "domain" => "schwab.com" } => true,
      { "name" => "E*Trade" }                           => true,
      { "domain" => "us.etrade.com" }                   => true,
      { "name" => "Chase" }                             => false,
      {}                                                => false
    }

    cases.each do |org, expected|
      account = Struct.new(:org_data).new(org)
      processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)
      assert_equal expected,
        processor.send(:institution_reports_total_basis?),
        "org_data #{org.inspect} expected #{expected}"
    end
  end

  test "cost_basis from Charles Schwab is divided by qty (#2626)" do
    # Schwab reports `cost_basis` as the total position cost, not per-share,
    # in violation of the SimpleFIN spec — same failure mode as Vanguard
    # (#1182) and Fidelity (#1718). Observed on two independent Sure
    # instances via raw SimpleFIN payloads, e.g.:
    #   { "shares" => "651.00", "cost_basis" => "30162.36", "purchase_price" => "46.33235" }
    # Left uncorrected, Holding#calculate_trend later multiplies this
    # (mislabeled-as-per-share) total by qty again when reconstructing the
    # position's original cost, inflating a holding's unrealized loss by
    # roughly qty× — e.g. a $46,950 position showing a -99.8% / -$19.6M
    # "return" instead of its true +55.7% gain.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("30162.36"),
      BigDecimal("651"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 46.33, cost_basis.to_f, 0.01
  end

  test "cost_basis from E*Trade is divided by qty (#3618)" do
    # Same failure mode as Vanguard/Fidelity (#1718) and Schwab (#2626):
    # E*Trade's cost_basis is total position cost, not per-share.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("3850.00"),
      BigDecimal("100"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 38.50, cost_basis.to_f, 0.01
  end

  test "parse_decimal tells an unreadable number from zero" do
    assert_equal 0, @processor.send(:parse_decimal, nil)
    assert_equal 0, @processor.send(:parse_decimal, "")
    assert_equal BigDecimal("0"), @processor.send(:parse_decimal, "0.0")
    assert_equal BigDecimal("12.5"), @processor.send(:parse_decimal, "12.5")
    assert_equal BigDecimal("3"), @processor.send(:parse_decimal, 3)

    assert_nil @processor.send(:parse_decimal, "invalid")
    assert_nil @processor.send(:parse_decimal, "NaN")
    assert_nil @processor.send(:parse_decimal, { "amount" => "1" })
  end

  test "missing cost basis fields return nil" do
    payload = {
      "market_value" => "10108.16"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_nil raw_cost_basis
    assert_nil source_key
    assert_nil cost_basis
  end

  test "lots of the same security combine into one position" do
    # SimpleFIN reports one record per lot. A 401k splitting employee deferral
    # from employer match sends two records for the same fund, and `holdings` is
    # uniquely indexed on (account_id, security_id, date, currency), so importing
    # them separately made the second overwrite the first.
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-b", "symbol" => "AAPL", "shares" => "11.891485", "market_value" => "3070.14", "cost_basis" => "200.00" },
      { "id" => "lot-a", "symbol" => "AAPL", "shares" => "2.378397",  "market_value" => "614.05",  "cost_basis" => "250.00" }
    ])
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)

    # The processor logs simplefin_account.id per lot, so the stub has to
    # answer it as well as account_provider.
    processor.stubs(:simplefin_account).returns(
      stub(id: "sfa-test", name: "Test Investment Account", account_provider: nil)
    )

    # A plain recorder rather than a mocha argument matcher, so the assertions
    # read against the real keyword arguments.
    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def import_holding(**kwargs)
        @calls << kwargs
        Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
              .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                   kwargs[:currency], kwargs[:date], kwargs[:external_id])
      end
    end.new

    processor.stubs(:import_adapter).returns(recorder)

    processor.process

    assert_equal 1, recorder.calls.size, "expected the two lots to collapse into a single position"

    position = recorder.calls.first
    assert_in_delta 14.269882, position[:quantity].to_f, 0.000001
    assert_in_delta 3684.19,   position[:amount].to_f,   0.01

    # cost_basis is stored per share, so lots combine as a share-weighted
    # average: (11.891485*200 + 2.378397*250) / 14.269882
    assert_in_delta 208.333, position[:cost_basis].to_f, 0.01

    # price is re-derived from the combined position
    assert_in_delta 258.1781, position[:price].to_f, 0.01
  end

  test "each day's sync keeps its own holding row" do
    # The external_id carries the snapshot date, so the next day's sync
    # creates a new row instead of finding yesterday's by id and moving it
    # forward. Without that, the account never has more than one row per
    # security and its holdings history collapses onto the latest day.
    account = accounts(:investment)
    security = Security.create!(ticker: "DAILY", name: "Daily Snapshot Fund")
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)
    processor.stubs(:account).returns(account)
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)
    processor.stubs(:simplefin_account).returns(
      stub(id: "sfa-test", name: "Test Investment Account", account_provider: nil)
    )

    first_day = Date.current

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-a", "symbol" => "DAILY", "shares" => "10", "market_value" => "1000" }
    ])
    processor.process

    travel_to 1.day.from_now do
      processor.stubs(:holdings_data).returns([
        { "id" => "lot-a", "symbol" => "DAILY", "shares" => "12", "market_value" => "1260" }
      ])
      processor.process
    end

    holdings = account.holdings.where(security: security).order(:date)

    assert_equal [ first_day, first_day + 1 ], holdings.map(&:date)
    assert_equal [ 10, 12 ], holdings.map { |h| h.qty.to_i }
    assert_equal [ "simplefin_lot-a_#{first_day}", "simplefin_lot-a_#{first_day + 1}" ], holdings.map(&:external_id)
  end

  test "a position missing from a later same-day payload loses its row for the day" do
    # A position sold during the day, or a sweep fund reported while a
    # deposit settled, would otherwise keep the row an earlier sync gave it,
    # and the balance history counts that row.
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    gone = Security.create!(ticker: "GONE", name: "Gone Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("GONE", anything).returns(gone)

    simplefin_account.update!(raw_holdings_payload: [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
      { "id" => "lot-g", "symbol" => "GONE", "shares" => "5", "market_value" => "500" }
    ])
    processor.process
    assert_equal 2, account.holdings.where(date: Date.current, account_provider: provider).count

    simplefin_account.update!(raw_holdings_payload: [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" }
    ])
    processor.process

    assert_equal [ kept.id ], account.holdings.where(date: Date.current, account_provider: provider).pluck(:security_id)
  end

  test "a later same-day payload leaves earlier days' rows alone" do
    account, provider, processor, simplefin_account = same_day_processor
    gone = Security.create!(ticker: "GONE", name: "Gone Fund")
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    processor.stubs(:resolve_security).with("GONE", anything).returns(gone)
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)

    travel_to 1.day.ago do
      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-g", "symbol" => "GONE", "shares" => "5", "market_value" => "500" }
      ])
      processor.process
    end

    simplefin_account.update!(raw_holdings_payload: [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" }
    ])
    processor.process

    assert_equal [ gone.id ], account.holdings.where(date: 1.day.ago.to_date, account_provider: provider).pluck(:security_id)
  end

  test "a payload with a position that failed to import removes nothing" do
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    other = Security.create!(ticker: "OTHER", name: "Other Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("OTHER", anything).returns(other)

    simplefin_account.update!(raw_holdings_payload: [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
      { "id" => "lot-o", "symbol" => "OTHER", "shares" => "5", "market_value" => "500" }
    ])
    processor.process

    processor.stubs(:resolve_security).with("OTHER", anything).returns(nil)
    processor.process

    assert_equal [ kept.id, other.id ].sort, account.holdings.where(date: Date.current, account_provider: provider).pluck(:security_id).sort
  end

  test "a payload with a record it cannot read removes nothing" do
    # A record with no id, or with neither a symbol nor a description, is
    # skipped without being imported, so its position's earlier row for the
    # day has to stay.
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    other = Security.create!(ticker: "OTHER", name: "Other Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("OTHER", anything).returns(other)

    [
      { "symbol" => "OTHER", "shares" => "5", "market_value" => "500" },
      { "id" => "lot-o", "shares" => "5", "market_value" => "500" }
    ].each do |unreadable|
      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
        { "id" => "lot-o", "symbol" => "OTHER", "shares" => "5", "market_value" => "500" }
      ])
      processor.process

      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
        unreadable
      ])
      processor.process

      assert_equal [ kept.id, other.id ].sort,
        account.holdings.where(date: Date.current, account_provider: provider).pluck(:security_id).sort,
        "purged a row for #{unreadable.inspect}"
    end
  end

  test "a position now reported with nothing in it loses its row for the day" do
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    gone = Security.create!(ticker: "GONE", name: "Gone Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("GONE", anything).returns(gone)

    [
      { "shares" => "0", "market_value" => "0" },
      { "shares" => 0, "market_value" => 0 },
      { "shares" => "0.0", "market_value" => "0.00" }
    ].each do |empty|
      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
        { "id" => "lot-g", "symbol" => "GONE", "shares" => "5", "market_value" => "500" }
      ])
      processor.process

      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
        { "id" => "lot-g", "symbol" => "GONE" }.merge(empty)
      ])
      processor.process

      assert_equal [ kept.id ], account.holdings.where(date: Date.current, account_provider: provider).pluck(:security_id),
        "kept a row for #{empty.inspect}"
    end
  end

  test "a record with a number it cannot read removes nothing" do
    # An unreadable quantity is not a zero quantity. Read as zero, the record
    # would look like an empty position and its earlier row would be purged.
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    other = Security.create!(ticker: "OTHER", name: "Other Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("OTHER", anything).returns(other)

    {
      { "shares" => "invalid", "market_value" => "0" } => [ "quantity" ],
      { "shares" => "0", "market_value" => "N/A" } => [ "market_value" ],
      { "shares" => "5", "price" => "unknown" } => [ "price" ]
    }.each do |numbers, fields|
      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
        { "id" => "lot-o", "symbol" => "OTHER", "shares" => "5", "market_value" => "500" }
      ])
      processor.process

      simplefin_account.update!(raw_holdings_payload: [
        { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
        { "id" => "lot-o", "symbol" => "OTHER" }.merge(numbers)
      ])
      assert_difference "DebugLogEntry.count", 1 do
        processor.process
      end

      assert_equal [ kept.id, other.id ].sort,
        account.holdings.where(date: Date.current, account_provider: provider).pluck(:security_id).sort,
        "purged a row for #{numbers.inspect}"

      skipped = DebugLogEntry.order(:created_at).last.metadata["not_imported"]
      assert_equal [ { "reason" => "malformed_number", "fields" => fields, "id" => "lot-o", "symbol" => "OTHER" } ], skipped
    end
  end

  test "an incomplete payload is recorded in the debug log" do
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("OTHER", anything).returns(nil)

    simplefin_account.update!(raw_holdings_payload: [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
      { "id" => "lot-o", "symbol" => "OTHER", "shares" => "5", "market_value" => "500" }
    ])

    assert_difference "DebugLogEntry.count", 1 do
      processor.process
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "simplefin", entry.provider_key
    assert_equal "warn", entry.level
    assert_equal account, entry.account
    assert_equal provider, entry.account_provider
    assert_equal account.family, entry.family
    assert_equal 1, entry.metadata["not_imported_count"]
    assert_equal "unresolved_security", entry.metadata["not_imported"].first["reason"]
  end

  test "a run whose payload was replaced mid-run changes nothing" do
    # The holdings apply job and the sync's own processing can run for the
    # same account at once. A run still working from an older payload must
    # neither delete rows the newer payload saved nor bring back or overwrite
    # rows from its own older payload.
    account, provider, processor, simplefin_account = same_day_processor
    kept = Security.create!(ticker: "KEPT", name: "Kept Fund")
    added = Security.create!(ticker: "ADDED", name: "Added Fund")
    gone = Security.create!(ticker: "GONE", name: "Gone Fund")
    processor.stubs(:resolve_security).with("KEPT", anything).returns(kept)
    processor.stubs(:resolve_security).with("ADDED", anything).returns(added)
    processor.stubs(:resolve_security).with("GONE", anything).returns(gone)

    simplefin_account.update!(raw_holdings_payload: [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "10", "market_value" => "1000" },
      { "id" => "lot-a", "symbol" => "ADDED", "shares" => "5", "market_value" => "500" }
    ])
    processor.process

    # This run read an older payload: KEPT at another quantity, GONE, and no
    # ADDED. A newer sync has since stored and applied the payload above.
    simplefin_account.raw_holdings_payload = [
      { "id" => "lot-k", "symbol" => "KEPT", "shares" => "7", "market_value" => "700" },
      { "id" => "lot-g", "symbol" => "GONE", "shares" => "3", "market_value" => "300" }
    ]
    processor.process

    today = account.holdings.where(date: Date.current, account_provider: provider)
    assert_equal [ added.id, kept.id ].sort, today.pluck(:security_id).sort
    assert_equal 10, today.find_by(security: kept).qty

    # Once the stored payload matches, the run applies it in full.
    simplefin_account.save!
    processor.process

    assert_equal [ gone.id, kept.id ].sort, today.pluck(:security_id).sort
    assert_equal 7, today.find_by(security: kept).qty
  end

  test "a position with any unknown-basis lot reports no aggregate basis" do
    # Averaging only the lots that reported a basis would apply that figure to
    # shares whose cost is unknown, fabricating cost and gain/loss.
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-known",   "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00", "cost_basis" => "100.00" },
      { "id" => "lot-unknown", "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00" }
    ])
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)
    processor.stubs(:simplefin_account).returns(
      stub(id: "sfa-test", name: "Test Investment Account", account_provider: nil)
    )

    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def import_holding(**kwargs)
        @calls << kwargs
        Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
              .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                   kwargs[:currency], kwargs[:date], kwargs[:external_id])
      end
    end.new

    processor.stubs(:import_adapter).returns(recorder)

    processor.process

    assert_equal 1, recorder.calls.size
    position = recorder.calls.first

    # quantity and value still aggregate
    assert_in_delta 20.0,   position[:quantity].to_f, 0.000001
    assert_in_delta 4000.0, position[:amount].to_f,   0.01

    # but the basis is unknown for the position as a whole, NOT $100/share
    assert_nil position[:cost_basis]
  end

  private
    def same_day_processor
      account = accounts(:investment)
      item = SimplefinItem.create!(family: account.family, name: "SimpleFIN", access_url: "https://example.com/access")
      simplefin_account = SimplefinAccount.create!(
        simplefin_item: item, name: "Brokerage", account_id: "sf_same_day",
        currency: "USD", account_type: "investment", current_balance: 0
      )
      provider = AccountProvider.create!(account: account, provider: simplefin_account)

      processor = SimplefinAccount::Investments::HoldingsProcessor.new(simplefin_account)
      processor.stubs(:account).returns(account)
      processor.stubs(:institution_reports_total_basis?).returns(false)

      [ account, provider, processor, simplefin_account ]
    end
end
