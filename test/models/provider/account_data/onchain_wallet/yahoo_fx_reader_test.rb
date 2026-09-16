require "test_helper"

class Provider::AccountData::OnchainWallet::YahooFxReaderTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  Wallet = Provider::AccountData::OnchainWallet
  Reader = Wallet::YahooFxReader

  setup do
    @date = Date.new(2026, 9, 15)
    @at = Time.utc(2026, 9, 15, 12).freeze
    @http = mock("one physical Yahoo GET per action")
    @reader = Reader.new(options: options, http: @http)
  end

  test "cookie 404 and crumb each capture one private bounded response without touching global auth cache" do
    Rails.expects(:cache).never
    @http.expects(:get).once.with("https://fc.yahoo.com", query: {}, headers: auth_headers, follow_redirects: false)
      .returns(response(404, "private unused body", "set-cookie" => "A3=private-cookie; Max-Age=31557600; Path=/; Secure"))
    cookie = read("cookie")
    assert_equal "response", cookie.fetch("status")
    assert_equal "A3=private-cookie", cookie.fetch("response").fetch("cookie")
    assert_equal (@at + 3600).iso8601(9), cookie.fetch("response").fetch("expires_at")
    assert_equal @at.iso8601(9), cookie.fetch("requested_at")
    assert cookie.frozen?
    assert cookie.fetch("response").frozen?
    refute_includes JSON.generate(cookie.fetch("request")), "private-cookie"
    refute_includes JSON.generate(cookie), "unused body"

    @http.expects(:get).once.with("https://fx.example.test/v1/test/getcrumb", query: {},
      headers: auth_headers.merge("Cookie" => "A3=private-cookie"), follow_redirects: false)
      .returns(response(200, " private/crumb= \n"))
    crumb = read("crumb", auth: { "cookie" => cookie }, requested_at: @at + 1)
    assert_equal "private/crumb=", crumb.fetch("response").fetch("crumb")
    assert_equal Reader.digest(cookie), crumb.fetch("response").fetch("cookie_digest")
    assert_equal cookie.dig("response", "expires_at"), crumb.dig("response", "expires_at")
    refute_includes @reader.inspect, "private"
  end

  test "direct chart uses explicit UTC bounds and normalizes exact decimals on the actual observation date" do
    auth = authenticate
    expected = { period1: Time.utc(2026, 9, 5).to_i, period2: Time.utc(2026, 9, 16).to_i,
      interval: "1d", includeAdjustedClose: true, crumb: "private-crumb" }
    headers = auth_headers.merge("Accept" => "application/json", "Cookie" => "A3=private-cookie", "Cache-Control" => "no-cache", "Pragma" => "no-cache")
    @http.expects(:get).once.with("https://fx.example.test/v8/finance/chart/USDEUR%3DX", query: expected, headers: headers, follow_redirects: false)
      .returns(response(200, chart_json(closes: "[0.891234567890123456]", dates: [ @date - 1 ])))
    capture = nil
    Time.use_zone("Pacific/Honolulu") { capture = read("chart", auth: auth, direction: "direct") }
    value = rate(capture)
    assert_equal "0.891234567890123456", value.fetch("rate")
    assert_equal "2026-09-14", value.fetch("date")
    assert_equal "direct", value.fetch("direction")
    assert_equal value.fetch("rate"), value.fetch("source_rate")
    refute_includes JSON.generate(capture), "private-cookie"
    refute_includes JSON.generate(capture), "private-crumb"
    assert_equal value, rate(JSON.parse(JSON.generate(capture)))
  end

  test "inverse chart retains source identity and reciprocal rounded to twelve decimal places" do
    auth = authenticate
    @http.expects(:get).once.with { |url, **args| url.end_with?("EURUSD%3DX") && args.fetch(:query).fetch(:crumb) == "private-crumb" }
      .returns(response(200, chart_json(symbol: "EURUSD=X", closes: "[3]")))
    capture = read("chart", auth: auth, direction: "inverse")
    value = rate(capture, direction: "inverse")
    assert_equal "0.333333333333", value.fetch("rate")
    assert_equal "3.0", value.fetch("source_rate")
    assert_equal "EURUSD=X", value.fetch("symbol")
    assert_nil rate(capture, direction: "direct")
    assert_nil Reader.rate(capture, from: "EUR", to: "USD", date: @date, auth_generation: 0, direction: "inverse")
  end

  test "unavailable pair and valid empty series stay distinct and never trigger an implicit inverse request" do
    auth = authenticate
    [ [ '{"chart":{"result":null,"error":{"code":"Not Found","description":"private-details"}}}', "pair_unavailable" ],
      [ chart_json(closes: "[]", dates: []), "response" ],
      [ '{"chart":{"result":[{"meta":{"symbol":"USDEUR=X"},"timestamp":null}]}}', "response" ] ].each do |body, status|
      @http.expects(:get).once.returns(response(200, body))
      capture = read("chart", auth: auth, direction: "direct")
      assert_equal status, capture.fetch("status")
      assert_nil rate(capture)
      refute_includes JSON.generate(capture), "private-details"
    end
  end

  test "latest eligible positive value keeps its source day and rejects conflicting observations" do
    auth = authenticate
    @http.expects(:get).once.returns(response(200,
      chart_json(closes: "[0.7,0.8,null,0,-1,0.9]", dates: [ @date - 11, @date - 10, @date - 2, @date - 1, @date, @date + 1 ])))
    value = rate(read("chart", auth: auth, direction: "direct"))
    assert_equal "0.8", value.fetch("rate")
    assert_equal (@date - 10).iso8601, value.fetch("date")

    @http.expects(:get).once.returns(response(200, chart_json(closes: "[0.8,0.9]", dates: [ @date, @date ])))
    assert_nil rate(read("chart", auth: auth, direction: "direct"))
  end

  test "future stale zero and null only responses cannot manufacture a current quote" do
    auth = authenticate
    [ [ "[0.9]", [ @date + 1 ] ], [ "[0.9]", [ @date - 11 ] ], [ "[0,null]", [ @date - 1, @date ] ] ].each do |closes, dates|
      @http.expects(:get).once.returns(response(200, chart_json(closes: closes, dates: dates)))
      assert_nil rate(read("chart", auth: auth, direction: "direct"))
    end
  end

  test "Unauthorized responses are captured without refreshing auth or retaining provider errors" do
    auth = authenticate
    @http.expects(:get).once.returns(response(200, '{"chart":{"error":{"code":"Unauthorized","description":"private-token"}}}'))
    capture = read("chart", auth: auth, direction: "direct")
    assert_equal "authentication_failed", capture.fetch("status")
    assert_empty capture.fetch("response")
    refute_includes JSON.generate(capture), "private-token"
  end

  test "authentication expiry is a reproducible local disposition and never lends expired credentials" do
    auth = authenticate(max_age: 60)
    @http.expects(:get).never
    capture = read("chart", auth: auth, direction: "direct", requested_at: @at + 60)
    assert_equal "auth_expired", capture.fetch("status")
    assert_nil capture.fetch("http_status")
    assert_empty capture.fetch("response")
    travel_to(@at + 2.days) { assert_nil rate(capture) }
  end

  test "physical request clock is sampled after pacing so a cookie expiring during the delay is never sent" do
    auth = authenticate(max_age: 60)
    events = []
    paced_at = @at + 59
    @reader.define_singleton_method(:pace!) do
      events << :pacing
      paced_at += 2
    end
    clock = -> { events << :clock; paced_at }
    @http.expects(:get).never
    capture = @reader.read(action: "chart", from: "USD", to: "EUR", date: @date, auth_generation: 0, direction: "direct",
      auth: auth, request_clock: clock)
    assert_equal [ :pacing, :clock ], events
    assert_equal "auth_expired", capture.fetch("status")
    assert_equal (@at + 61).iso8601(9), capture.fetch("requested_at")
    assert_equal "2026-09-15", capture.dig("request", "date")
    assert_nil capture.fetch("http_status")
  end

  test "wrong auth generation configuration pair chronology or cookie-crumb binding is refused before HTTP" do
    auth = authenticate
    @http.expects(:get).never
    assert_raises(Provider::AccountData::StaleWriter) { read("chart", auth: auth, direction: "direct", auth_generation: 1) }
    assert_raises(Provider::AccountData::StaleWriter) { read("chart", auth: auth, direction: "direct", to: "GBP") }
    assert_raises(Provider::AccountData::StaleWriter) { read("chart", auth: auth, direction: "direct", requested_at: @at - 1) }
    foreign = Reader.new(options: options.merge("endpoint" => "https://other.example.test"), http: @http)
    assert_raises(Provider::AccountData::StaleWriter) { read("chart", auth: auth, direction: "direct", reader: foreign) }
    changed = auth.deep_dup
    changed.fetch("cookie").fetch("response")["cookie"] = "A3=another-cookie"
    assert_raises(Provider::AccountData::StaleWriter) { read("chart", auth: changed, direction: "direct") }
  end

  test "rate limits server errors and transport errors are sanitized and do not yield terminal captures" do
    [ [ 429, Wallet::Readers::RateLimited ], [ 503, Wallet::Readers::Error ] ].each do |code, klass|
      @http.expects(:get).once.returns(response(code, "private-body"))
      error = assert_raises(klass) { read("cookie") }
      refute_includes error.message, "private-body"
      assert_nil error.cause
    end
    @http.expects(:get).once.raises(Net::ReadTimeout, "https://private?crumb=secret")
    error = assert_raises(Wallet::Readers::Error) { read("cookie") }
    refute_includes error.message, "secret"
    assert_nil error.cause
    cookie = authenticate.fetch("cookie")
    @http.expects(:get).once.returns(response(200, " Too Many Requests \n"))
    assert_raises(Wallet::Readers::RateLimited) { read("crumb", auth: { "cookie" => cookie }) }
  end

  test "malformed oversized and contradictory chart data never become a rate" do
    auth = authenticate
    bodies = [ "not-json", "[]", " " * (Reader::MAX_BYTES + 1), chart_json(symbol: "EURUSD=X"),
      chart_json(closes: '["NaN"]'), chart_json(closes: "[1e9999]"), chart_json(closes: "[]"),
      chart_json(closes: "[#{Array.new(33, '0.9').join(',')}]", dates: Array.new(33, @date)) ]
    bodies.each do |body|
      @http.expects(:get).once.returns(response(200, body))
      capture = read("chart", auth: auth, direction: "direct")
      assert_equal "invalid_response", capture.fetch("status")
      assert_nil rate(capture)
    end
  end

  test "cookie and crumb private envelopes have tighter bounds and never retain malformed inputs" do
    [ "A3=#{'s' * Reader::MAX_COOKIE_BYTES}", "A3=x; Max-Age=oops", "A3=x; Max-Age=60; max-age=90", "A3=x\r\nInjected=yes" ].each do |header|
      @http.expects(:get).once.returns(response(404, "", "set-cookie" => header))
      capture = read("cookie")
      refute_equal "response", capture.fetch("status")
      assert_empty capture.fetch("response")
    end
    cookie = authenticate.fetch("cookie")
    [ "", "s" * (Reader::MAX_CRUMB_BYTES + 1), "crumb\nsecond-line" ].each do |body|
      @http.expects(:get).once.returns(response(200, body))
      capture = read("crumb", auth: { "cookie" => cookie })
      refute_equal "response", capture.fetch("status")
      assert_empty capture.fetch("response")
    end
  end

  test "redirects and terminal errors are captured without following locations" do
    [ 302, 401, 403, 404 ].each do |code|
      @http.expects(:get).once.with { |_url, **args| args.fetch(:follow_redirects) == false }
        .returns(response(code, "private-response", "location" => "https://private-location"))
      capture = read("cookie")
      refute_equal "response", capture.fetch("status")
      refute_includes JSON.generate(capture), "private-"
    end
  end

  test "requests cannot occur in a row transaction and invalid captured configuration fails before HTTP" do
    @http.expects(:get).never
    ApplicationRecord.transaction do
      assert_raises(Provider::AccountData::InvalidResponse) { read("cookie") }
    end
    [ { "endpoint" => "https://user:secret@host.test" }, { "endpoint" => "https://host.test?key=secret" },
      { "user_agent" => "agent\nsecret" }, { "min_interval_seconds" => "NaN" }, { "provider" => "moex_public" } ].each do |change|
      error = assert_raises(ArgumentError) { Reader.new(options: options.merge(change), http: @http) }
      refute_includes error.message, "secret"
    end
  end

  test "real HTTParty connection configuration disables Net HTTP automatic retries" do
    connection = HTTParty::ConnectionAdapter.call(URI("https://fx.example.test"), Reader::Http.default_options)
    assert_equal 0, connection.max_retries
    refute connection.started?
  end

  private
    def options
      { "version" => 1, "provider" => "yahoo_finance", "endpoint" => "https://fx.example.test", "user_agent" => "captured-agent/v1", "min_interval_seconds" => "0" }
    end

    def auth_headers
      { "User-Agent" => "captured-agent/v1", "Accept" => "*/*", "Accept-Language" => "en-US,en;q=0.9" }
    end

    def read(action, reader: @reader, **overrides)
      reader.read(**{ action: action, from: "USD", to: "EUR", date: @date, auth_generation: 0, requested_at: @at }.merge(overrides))
    end

    def rate(capture, direction: "direct")
      Reader.rate(capture, from: "USD", to: "EUR", date: @date, auth_generation: 0, direction: direction)
    end

    def authenticate(max_age: 3600)
      @http.expects(:get).once.returns(response(404, "", "set-cookie" => "A3=private-cookie; Max-Age=#{max_age}"))
      cookie = read("cookie")
      @http.expects(:get).once.returns(response(200, "private-crumb"))
      { "cookie" => cookie, "crumb" => read("crumb", auth: { "cookie" => cookie }) }
    end

    def response(code, body, headers = {})
      stub(code: code, body: body, headers: headers)
    end

    def chart_json(symbol: "USDEUR=X", closes: "[0.9]", dates: [ @date ])
      timestamps = dates.map { |date| Time.utc(date.year, date.month, date.day).to_i }
      %({"chart":{"error":null,"result":[{"meta":{"symbol":#{JSON.generate(symbol)}},"timestamp":#{JSON.generate(timestamps)},"indicators":{"quote":[{"close":#{closes}}]}}]}})
    end
end
