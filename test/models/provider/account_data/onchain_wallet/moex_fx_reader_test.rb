require "test_helper"

class Provider::AccountData::OnchainWallet::MoexFxReaderTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  Wallet = Provider::AccountData::OnchainWallet
  Reader = Wallet::MoexFxReader

  setup do
    @date = Date.new(2026, 9, 15)
    @options = { "version" => 1, "provider" => "moex_public", "endpoint" => "https://moex.example.test/iss",
      "min_interval_seconds" => "0.4", "history_policy" => Reader.policy }
    @http = mock("one physical ISS history response")
    @reader = Reader.new(options: @options, http: @http)
    @reader.stubs(:sleep)
  end

  test "one bounded history request retains reordered exact identity and decimals while excluding unrelated fields" do
    history = { "columns" => %w[WAPRICE TRADEDATE SECID BOARDID CLOSE PRIVATE_FIELD],
      "data" => [ [ "1", "2026-09-14", "USD000UTSTOM", "CETS", "91.123456789012345678", "private-unrelated-value" ] ] }
    @http.expects(:get).once.with do |url, **options|
      assert_equal 0, ApplicationRecord.connection.open_transactions
      url == "https://moex.example.test/iss/history/engines/currency/markets/selt/boards/CETS/securities/USD000UTSTOM.json" &&
        options == { query: { "iss.meta" => "off", "iss.only" => "history", "from" => "2026-09-05", "till" => "2026-09-15", "start" => 0 },
          headers: { "Accept" => "application/json" }, follow_redirects: false }
    end.returns(stub(code: 200, body: JSON.generate("history" => history).sub('"91.123456789012345678"', "91.123456789012345678")))
    captured = @reader.read(from: "USD", to: "RUB", date: @date, start: 0)
    refute_includes JSON.generate(captured), "private-unrelated-value"
    result = acquire { |_action, **_arguments| captured }
    assert_equal "91.123456789012345678", result.fetch("rate")
    assert_equal "2026-09-14", result.fetch("date")
    assert_equal "close", result.fetch("field")
    assert_equal "CETS", result.fetch("board")
    refute result.fetch("inverted")
  end

  test "all reviewed RUB instruments preserve direct rates and twelve-place inverse provenance" do
    Reader::INSTRUMENTS.each do |currency, instrument|
      [ [ currency, "RUB", false ], [ "RUB", currency, true ] ].each do |from, to, inverted|
        captured = capture([ row(instrument: instrument, close: "3", waprice: "4") ], from: from, to: to)
        result = acquire(from: from, to: to) { |_action, **_arguments| captured }
        assert_equal instrument, result.fetch("instrument")
        assert_equal inverted, result.fetch("inverted")
        assert_equal "3.0", result.fetch("original_rate")
        assert_equal(inverted ? "0.333333333333" : "3.0", result.fetch("rate"))
      end
    end
  end

  test "history selects a proven date within ten days and uses WAPRICE only when CLOSE is absent" do
    captured = capture([ row(day: "2026-09-05", close: nil, waprice: "90"), row(day: "2026-09-14", close: "0", waprice: "100") ])
    result = acquire { |_action, **_arguments| captured }
    assert_equal "2026-09-05", result.fetch("date")
    assert_equal "90.0", result.fetch("rate")
    assert_equal "waprice", result.fetch("field")
    assert_nil acquire { |_action, **_arguments| capture([]) }
  end

  test "missing future stale malformed or contradictory identity and dates cannot become a quote" do
    invalid_rows = [ row(day: nil), row(day: "2026-09-16"), row(day: "2026-09-04"), row(day: "2026-9-05"),
      row(instrument: "CNYRUB_TOM"), row(board: "OTHER"), row(close: "NaN"), row(close: "Infinity") ]
    invalid_rows.each do |invalid|
      assert_raises(Reader::EnvelopeError) { acquire { |_action, **_arguments| capture([ invalid ]) } }
    end
    changed = capture([ row ])
    changed["request"]["start"] = 100
    assert_raises(Reader::EnvelopeError) { acquire { |_action, **_arguments| changed } }
  end

  test "ambiguous ISS columns malformed rows oversized bodies and unsupported response shapes reject before capture" do
    normal = capture([ row ]).fetch("history")
    invalid = [ {}, { "history" => normal.merge("columns" => normal["columns"] + [ "close" ]) },
      { "history" => normal.merge("data" => [ row.first(4) ]) },
      { "history" => normal.merge("data" => Array.new(101) { row }) },
      { "history" => { "columns" => %w[SECID TRADEDATE CLOSE], "data" => [] } },
      { "history" => normal.merge("data" => [ row(close: "x" * 129) ]) } ]
    invalid.each do |body|
      @http.expects(:get).once.returns(stub(code: 200, body: JSON.generate(body)))
      assert_raises(Reader::EnvelopeError) { @reader.read(from: "USD", to: "RUB", date: @date, start: 0) }
    end
    [ "not-json", " " * (Reader::MAX_BYTES + 1) ].each do |body|
      @http.expects(:get).once.returns(stub(code: 200, body: body))
      assert_raises(Reader::EnvelopeError) { @reader.read(from: "USD", to: "RUB", date: @date, start: 0) }
    end
  end

  test "full pages advance only their captured offset and replay never requests another physical response" do
    bodies = [ capture(Array.new(100) { row(day: "2026-09-05", close: "90") }).fetch("history"),
      capture([ row(day: "2026-09-14", close: "91") ], start: 100).fetch("history") ]
    [ 0, 100 ].each_with_index do |start, index|
      @http.expects(:get).once.with { |_url, **options| options.dig(:query, "start") == start }
        .returns(stub(code: 200, body: JSON.generate("history" => bodies[index])))
    end
    captured = []
    result = acquire do |action, **arguments|
      assert_equal "fx_moex_history", action
      value = @reader.read(**arguments.merge(date: Date.iso8601(arguments.fetch(:date))))
      captured << [ arguments, value ]
      value
    end
    assert_equal "91.0", result.fetch("rate")
    assert_equal [ 0, 100 ], captured.map { |arguments, _value| arguments.fetch(:start) }
    replayed = acquire do |_action, **arguments|
      captured.find { |expected, _value| expected == arguments }&.last || flunk("Unexpected replay operation")
    end
    assert_equal result, replayed
  end

  test "conflicting same-date observations and a full final budget page never yield partial valuation" do
    calls = 0
    assert_raises(Provider::AccountData::InvalidResponse) do
      acquire do |_action, **arguments|
        calls += 1
        capture(arguments[:start].zero? ? Array.new(100) { row(close: "90") } : [ row(close: "91") ], start: arguments[:start])
      end
    end
    assert_equal 2, calls
    @options["history_policy"]["max_pages"] = 2
    calls = 0
    assert_raises(Provider::AccountData::IncompletePage) do
      acquire do |_action, **arguments|
        calls += 1
        capture(Array.new(100) { row }, start: arguments[:start])
      end
    end
    assert_equal 2, calls
  end

  test "unsupported pairs are captured without HTTP and no current-marketdata action is requested" do
    @http.expects(:get).never
    captured = @reader.read(from: "USD", to: "EUR", date: @date, start: 0)
    assert_equal "unsupported_pair", captured.fetch("status")
    assert_nil acquire(from: "USD", to: "EUR") { |action, **_arguments| assert_equal "fx_moex_history", action; captured }
    actions = []
    assert_nil acquire { |action, **_arguments| actions << action; capture([]) }
    assert_equal [ "fx_moex_history" ], actions
  end

  test "transport failures leave the operation pending and database transactions cannot perform HTTP" do
    [ [ 429, Wallet::Readers::RateLimited ], [ 503, Reader::EnvelopeError ], [ 302, Reader::EnvelopeError ] ].each do |status, error_class|
      @http.expects(:get).once.returns(stub(code: status, body: "private-response"))
      error = assert_raises(error_class) { @reader.read(from: "USD", to: "RUB", date: @date, start: 0) }
      refute_includes error.message, "private-response"
    end
    @http.expects(:get).once.raises(Net::ReadTimeout, "private-endpoint")
    error = assert_raises(Wallet::Readers::Error) { @reader.read(from: "USD", to: "RUB", date: @date, start: 0) }
    assert_nil error.cause
    refute_includes error.message, "private-endpoint"
    ApplicationRecord.transaction do
      assert_raises(Provider::AccountData::InvalidResponse) { @reader.read(from: "USD", to: "RUB", date: @date, start: 0) }
    end
  end

  test "wallet FX and public price connections disable underlying Net HTTP retries without opening a socket" do
    [ Reader::Http, Wallet::FxReader::Http, Wallet::Client::PublicHttp ].each do |http|
      connection = HTTParty::ConnectionAdapter.call(URI("https://example.test"), http.default_options)
      assert_equal 0, connection.max_retries
      refute connection.started?
    end
  end

  private
    def row(instrument: "USD000UTSTOM", board: "CETS", day: "2026-09-14", close: "91", waprice: nil)
      [ board, instrument, day, close, waprice ]
    end

    def capture(rows, from: "USD", to: "RUB", start: 0)
      { "version" => 1, "provider" => "moex_public", "status" => "response",
        "request" => Reader.request(options: @options, from: from, to: to, date: @date, start: start),
        "history" => { "columns" => %w[BOARDID SECID TRADEDATE CLOSE WAPRICE], "data" => rows } }
    end

    def acquire(from: "USD", to: "RUB", &read)
      Wallet::FxAcquisition.new(options: @options, from: from, to: to, date: @date, read: read).call
    end
end
