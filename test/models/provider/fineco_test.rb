require "test_helper"

class Provider::FinecoTest < ActiveSupport::TestCase
  setup do
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
  end

  SUMMARY = {
    "currencyCd" => "EUR",
    "bookValue" => 90,
    "marketValue" => 100,
    "profitLoss" => 10,
    "profitLossPerc" => 11.11,
    "accrual" => 0
  }.freeze

  POSITION = {
    "instrId" => "US0000000002",
    "venueSystem" => "XETRA",
    "symbol" => "TEST",
    "type" => "etf",
    "currencyCd" => "EUR",
    "qty" => 2,
    "avgPrice" => 45,
    "marketPrice" => 50,
    "bookValue" => 90,
    "marketValue" => 100,
    "profitLoss" => 10,
    "profitLossPerc" => 11.11,
    "accrual" => 0
  }.freeze

  class StubResponse
    attr_reader :code

    def initialize(code:, body: "", headers: {})
      @code = code.to_s
      @body = body
      @headers = headers.each_with_object({}) do |(key, value), values|
        values[key.downcase] = value
      end
    end

    def [](name)
      Array(@headers[name.downcase]).first
    end

    def get_fields(name)
      value = @headers[name.downcase]
      value.nil? ? nil : Array(value)
    end

    def read_body
      yield @body
    end
  end

  class StubHttp
    attr_accessor :use_ssl, :verify_mode, :verify_hostname, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_objects, :request_count

    def initialize(responses, failure: nil)
      @responses = Array(responses)
      @failure = failure
      @request_count = 0
      @request_objects = []
    end

    def start
      yield self
    end

    def request(request)
      @request_count += 1
      @request_objects << request
      raise @failure if @failure

      response = @responses.shift
      yield response if block_given?
      response
    end
  end

  test "fetches the fixed HTTPS endpoint with the captured context and gsessionid only" do
    http = stub_http(success_response)

    result = with_http(http) do
      fineco.fetch_portfolio_summary
    end

    identity_request, request = http.request_objects
    assert_equal Provider::Fineco::ACCOUNT_LIST_ENDPOINT.request_uri, identity_request.path
    assert_instance_of Net::HTTP::Get, request
    assert_equal Provider::Fineco::ENDPOINT.request_uri, request.path
    assert_equal "gsessionid=opaque-session", request["Cookie"]
    assert_nil request["Authorization"]
    assert_nil request["X-CSRF-Token"]
    assert_equal "2", request["X-Account-Index"]
    assert_equal "11", request["X-Dossier-Index"]
    assert_equal "gsessionid=opaque-session", identity_request["Cookie"]
    assert_equal "2", identity_request["X-Account-Index"]
    assert_equal "11", identity_request["X-Dossier-Index"]
    assert http.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert http.verify_hostname
    assert_equal Provider::Fineco::OPEN_TIMEOUT_SECONDS, http.open_timeout
    assert_equal Provider::Fineco::READ_TIMEOUT_SECONDS, http.read_timeout
    assert_equal Provider::Fineco::WRITE_TIMEOUT_SECONDS, http.write_timeout
    assert_equal SUMMARY["marketValue"], result.payload.dig("summary", "total", "marketValue")
    assert_equal "23456789", result.account_number
    assert_equal 64, result.dossier_identity.length
  end

  test "does not make an HTTP request until the identity contract is verified" do
    Provider::Fineco.expects(:verified_identity_contract?).returns(false)
    Net::HTTP.expects(:new).never

    error = assert_raises Provider::Fineco::IdentityVerificationRequired do
      fineco.fetch_portfolio_summary
    end

    assert_match(/identity verification is required/i, error.message)
    refute_includes error.message, "opaque-session"
  end

  test "rejects cookies containing separators or header injection before a request" do
    [ "session;evil", "session\r\nX-Injected: yes", "session value", "" ].each do |value|
      assert_raises Provider::Fineco::ConfigurationError do
        Provider::Fineco.new(gsessionid: value, account_index: "0", dossier_index: "0")
      end
    end

    [ "0\r\nX-Injected: yes", "1;other", "", "1234567" ].each do |value|
      assert_raises Provider::Fineco::ConfigurationError do
        Provider::Fineco.new(gsessionid: "opaque-session", account_index: value, dossier_index: "0")
      end
    end
  end

  test "requires explicit selected account and dossier indexes" do
    assert_raises Provider::Fineco::ConfigurationError do
      Provider::Fineco.new(gsessionid: "opaque-session", account_index: 0, dossier_index: "0")
    end
  end

  test "maps 401 and 403 to reauthentication without following redirects" do
    [ 401, 403 ].each do |status|
      assert_raises Provider::Fineco::ReauthenticationRequired do
        with_http(stub_http(StubResponse.new(code: status))) do
          fineco.fetch_portfolio_summary
        end
      end
    end

    http = stub_http(StubResponse.new(code: 302, headers: { "location" => "https://evil.example/collect" }))
    assert_raises Provider::Fineco::RedirectRejected do
      with_http(http) { fineco.fetch_portfolio_summary }
    end
    assert_equal 2, http.request_count
  end

  test "verifies the selected bank account and dossier before requesting positions" do
    identity = identity_payload
    identity["accounts"][1]["dossiers"] = [
      { "index" => 10, "number" => 20_010, "header" => "Other" },
      { "number" => 20_011, "index" => 11, "header" => "Portfolio" }
    ]
    with_http(stub_http(success_response, identity: json_response(identity))) do |stub|
      result = fineco.fetch_portfolio_summary

      assert_equal "23456789", result.account_number
      assert_equal 64, result.dossier_identity.length
      assert_equal 2, stub.request_count
    end
  end

  test "does not retain rotation or bank context from an invalid identity response" do
    invalid_identity = identity_payload
    invalid_identity["accounts"][1].delete("number")
    rotated = json_response(
      invalid_identity,
      headers: { "set-cookie" => "gsessionid=unverified-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = stub_identity_http(rotated)
    client = fineco

    assert_raises Provider::Fineco::InvalidResponse do
      with_http(http) { client.fetch_portfolio_summary }
    end

    assert_equal 1, http.request_count
    assert_nil client.last_rotated_gsessionid
    assert_nil client.last_verified_bank_identity
    refute_includes client.inspect, "unverified-session"
  end

  test "canonical identity ignores selector indexes and mutable dossier descriptors" do
    first_result = with_http(stub_http(success_response)) { fineco.fetch_portfolio_summary }
    changed = identity_payload
    changed_account = changed["accounts"][1]
    changed_account["index"] = 9
    changed_account["header"] = "Changed account header"
    changed_account["equityEnabled"] = false
    changed_account["fundEnabled"] = true
    changed_account["hasSubAccounts"] = true
    changed_account["tradingEnabled"] = false
    changed_dossier = changed_account["dossiers"].first
    changed_dossier["index"] = 19
    changed_dossier["header"] = "Changed dossier header"
    changed_dossier["type"] = "changed"
    changed_dossier["equityEnabled"] = false
    changed_dossier["fundEnabled"] = true
    changed_dossier["hasSubAccounts"] = true
    changed_dossier["tradingEnabled"] = false

    second_result = with_http(stub_http(success_response, identity: json_response(changed))) do
      Provider::Fineco.new(
        gsessionid: "opaque-session",
        account_index: "9",
        dossier_index: "19"
      ).fetch_portfolio_summary
    end

    assert_equal first_result.account_number, second_result.account_number
    assert_equal first_result.dossier_identity, second_result.dossier_identity

    changed_dossier["number"] += 1
    changed_number_result = with_http(stub_http(success_response, identity: json_response(changed))) do
      Provider::Fineco.new(
        gsessionid: "opaque-session",
        account_index: "9",
        dossier_index: "19"
      ).fetch_portfolio_summary
    end

    refute_equal first_result.dossier_identity, changed_number_result.dossier_identity

    changed_account_identity = identity_payload
    changed_account_identity["accounts"][1]["number"] += 1
    changed_account_result = with_http(stub_http(success_response, identity: json_response(changed_account_identity))) do
      fineco.fetch_portfolio_summary
    end

    refute_equal first_result.dossier_identity, changed_account_result.dossier_identity
  end

  test "canonicalizes positive safe integer business numbers without float conversion" do
    identity = identity_payload
    identity["accounts"][1]["number"] = Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER
    identity["accounts"][1]["dossiers"][0]["number"] = Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER - 1

    result = with_http(stub_http(success_response, identity: json_response(identity))) do
      fineco.fetch_portfolio_summary
    end

    assert_equal Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER.to_s, result.account_number
    expected_identity = Digest::SHA256.hexdigest(
      JSON.generate(
        [
          Provider::Fineco::IDENTITY_NAMESPACE,
          Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER.to_s,
          (Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER - 1).to_s
        ]
      )
    )
    assert_equal expected_identity, result.dossier_identity
  end

  test "rejects unknown, ambiguous, or incomplete account and dossier identity" do
    missing_account = identity_payload
    missing_account["accounts"][1]["index"] = 9
    assert_identity_rejected(missing_account)

    duplicate_account = identity_payload
    duplicate_account["accounts"][0]["number"] = duplicate_account["accounts"][1]["number"]
    assert_identity_rejected(duplicate_account)

    duplicate_account_index = identity_payload
    duplicate_account_index["accounts"] << {
      "index" => 2,
      "number" => 34_567_890,
      "dossiers" => [ { "index" => 12, "number" => 34_512 } ]
    }
    assert_identity_rejected(duplicate_account_index)

    missing_number = identity_payload
    missing_number["accounts"][1].delete("number")
    assert_identity_rejected(missing_number)

    [ nil, "23456789", 0, -1, Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER + 1, 2.5 ].each do |number|
      invalid_number = identity_payload
      invalid_number["accounts"][1]["number"] = number
      assert_identity_rejected(invalid_number)
    end

    missing_dossier = identity_payload
    missing_dossier["accounts"][1]["dossiers"].clear
    assert_identity_rejected(missing_dossier)

    duplicate_dossier = identity_payload
    duplicate_dossier["accounts"][1]["dossiers"] << duplicate_dossier["accounts"][1]["dossiers"].first.merge("index" => 12)
    assert_identity_rejected(duplicate_dossier)

    duplicate_dossier_index = identity_payload
    duplicate_dossier_index["accounts"][1]["dossiers"] << {
      "index" => 11,
      "number" => 20_012
    }
    assert_identity_rejected(duplicate_dossier_index)

    [ nil, "20011", 0, -1, Provider::Fineco::MAX_SAFE_BUSINESS_NUMBER + 1, 2.5 ].each do |number|
      invalid_number = identity_payload
      invalid_number["accounts"][1]["dossiers"][0]["number"] = number
      assert_identity_rejected(invalid_number)
    end

    index_only_dossier = identity_payload
    index_only_dossier["accounts"][1]["dossiers"] = [ { "index" => 11 } ]
    assert_identity_rejected(index_only_dossier)
  end

  test "uses a safely rotated identity cookie for the portfolio request" do
    rotated = json_response(
      identity_payload,
      headers: { "set-cookie" => "gsessionid=rotated-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = stub_http(success_response, identity: rotated)

    result = with_http(http) { fineco.fetch_portfolio_summary }

    assert_equal "gsessionid=rotated-session", http.request_objects.last["Cookie"]
    assert_equal "rotated-session", result.rotated_gsessionid
  end

  test "retains a validated rotation when portfolio validation fails" do
    rotated_identity = json_response(
      identity_payload,
      headers: { "set-cookie" => "gsessionid=identity-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    incomplete_payload = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    incomplete_payload["positions"]["show"].first.delete("marketPrice")
    rotated_portfolio = json_response(
      incomplete_payload,
      headers: { "set-cookie" => "gsessionid=portfolio-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = stub_http(rotated_portfolio, identity: rotated_identity)
    client = fineco

    error = assert_raises Provider::Fineco::InvalidResponse do
      with_http(http) { client.fetch_portfolio_summary }
    end

    assert_equal "Fineco returned an incomplete portfolio position.", error.message
    assert_equal "gsessionid=identity-session", http.request_objects.last["Cookie"]
    assert_equal "identity-session", client.last_rotated_gsessionid
    refute_includes client.inspect, "identity-session"
    refute_includes client.to_s, "identity-session"
  end

  test "retries one quote-incomplete portfolio response and accepts only a complete snapshot" do
    rotated_identity = json_response(
      identity_payload,
      headers: { "set-cookie" => "gsessionid=identity-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    incomplete = json_response(
      quote_data_unavailable_payload,
      headers: { "set-cookie" => "gsessionid=portfolio-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = StubHttp.new([ rotated_identity, incomplete, success_response ])
    client = fineco

    result = with_http(http) { client.fetch_portfolio_summary }

    assert_equal 3, http.request_count
    assert_equal "gsessionid=identity-session", http.request_objects[1]["Cookie"]
    assert_equal "gsessionid=portfolio-session", http.request_objects[2]["Cookie"]
    assert_equal [ POSITION ], result.payload.dig("positions", "show")
    assert_equal "portfolio-session", result.rotated_gsessionid
  end

  test "rejects a second quote-incomplete portfolio response without a third read" do
    first_incomplete = json_response(
      quote_data_unavailable_payload,
      headers: { "set-cookie" => "gsessionid=first-rotation; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    second_incomplete = json_response(
      quote_data_unavailable_payload,
      headers: { "set-cookie" => "gsessionid=second-rotation; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = StubHttp.new([ json_response(identity_payload), first_incomplete, second_incomplete ])
    client = fineco

    error = assert_raises Provider::Fineco::MarketDataUnavailable do
      with_http(http) { client.fetch_portfolio_summary }
    end

    assert_equal "Fineco temporarily omitted market data for a portfolio position.", error.message
    assert_equal 3, http.request_count
    assert_equal "gsessionid=first-rotation", http.request_objects[2]["Cookie"]
    assert_equal "second-rotation", client.last_rotated_gsessionid
  end

  test "does not retry quote omissions when a position identity is invalid" do
    invalid_identity = quote_data_unavailable_payload
    invalid_identity["positions"]["show"][0]["instrId"] = "not-an-isin"
    http = stub_http(json_response(invalid_identity))

    assert_raises Provider::Fineco::InvalidResponse do
      with_http(http) { fineco.fetch_portfolio_summary }
    end

    assert_equal 2, http.request_count
  end

  test "does not classify quote omissions when a later position is unsupported" do
    missing_quotes = POSITION.except(*Provider::Fineco::POSITION_MARKET_DATA_FIELDS)
    unsupported_position = POSITION.merge("type" => "option")
    summary = SUMMARY.merge("bookValue" => 180, "marketValue" => 200, "profitLoss" => 20)
    payload = complete_payload(positions: [ missing_quotes, unsupported_position ], summary: summary)
    response = json_response(
      payload,
      headers: { "set-cookie" => "gsessionid=unverified-portfolio-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = stub_http(response)
    client = fineco

    error = assert_raises Provider::Fineco::InvalidResponse do
      with_http(http) { client.fetch_portfolio_summary }
    end

    assert_equal "Fineco returned an unsupported portfolio position.", error.message
    assert_equal 2, http.request_count
    assert_nil client.last_rotated_gsessionid
  end

  test "does not classify quote omissions when EUR summary totals are inconsistent" do
    payload = quote_data_unavailable_payload
    payload["summary"]["total"]["marketValue"] += 1
    response = json_response(
      payload,
      headers: { "set-cookie" => "gsessionid=unverified-portfolio-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = stub_http(response)
    client = fineco

    error = assert_raises Provider::Fineco::InvalidResponse do
      with_http(http) { client.fetch_portfolio_summary }
    end

    assert_instance_of Provider::Fineco::InvalidResponse, error
    assert_equal "Fineco returned partial portfolio totals.", error.message
    assert_equal 2, http.request_count
    assert_nil client.last_rotated_gsessionid
  end

  test "does not classify quote omissions when portfolio summary currency is not EUR" do
    payload = quote_data_unavailable_payload
    payload["summary"]["show"]["currencyCd"] = "USD"
    payload["summary"]["total"]["currencyCd"] = "USD"
    response = json_response(
      payload,
      headers: { "set-cookie" => "gsessionid=unverified-portfolio-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly" }
    )
    http = stub_http(response)
    client = fineco

    error = assert_raises Provider::Fineco::InvalidResponse do
      with_http(http) { client.fetch_portfolio_summary }
    end

    assert_instance_of Provider::Fineco::InvalidResponse, error
    assert_equal "Fineco returned an invalid portfolio currency.", error.message
    assert_equal 2, http.request_count
    assert_nil client.last_rotated_gsessionid
  end

  test "maps the Fineco read-time SCA response and recognized HTML challenges to reauthentication" do
    response = StubResponse.new(
      code: 451,
      body: '{"issues":[{"reason":"Sca di sessione non valida"}]}',
      headers: {
        "content-type" => "application/json",
        "set-cookie" => "gsessionid=step-up-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly"
      }
    )
    http = stub_http(response)
    client = fineco
    assert_raises Provider::Fineco::ReauthenticationRequired do
      with_http(http) { client.fetch_portfolio_summary }
    end
    assert_equal 2, http.request_count
    assert_nil client.last_rotated_gsessionid

    html = StubResponse.new(
      code: 200,
      body: "<html><body>strong_auth</body></html>",
      headers: { "content-type" => "text/html" }
    )
    http = stub_http(html)
    assert_raises Provider::Fineco::ReauthenticationRequired do
      with_http(http) { fineco.fetch_portfolio_summary }
    end
    assert_equal 2, http.request_count
  end

  test "rejects HTML and malformed JSON without presenting an empty complete portfolio" do
    [ "<html><body>login</body></html>", "{not-json" ].each do |body|
      response = StubResponse.new(code: 200, body: body)
      assert_raises Provider::Fineco::InvalidResponse do
        with_http(stub_http(response)) { fineco.fetch_portfolio_summary }
      end
    end
  end

  test "does not retain malformed response data in exception causes" do
    malformed = StubResponse.new(code: 200, body: '{"private_marker":{not-json}')
    error = assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(malformed)) { fineco.fetch_portfolio_summary }
    end
    assert_nil error.cause
    refute_includes error.message, "private_marker"

    invalid_number = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    invalid_number["summary"]["total"]["marketValue"] = "sensitive malformed value"
    error = assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(invalid_number))) { fineco.fetch_portfolio_summary }
    end
    assert_nil error.cause
    refute_includes error.message, "sensitive malformed value"
  end

  test "accepts only an explicit empty positions array with complete zero totals" do
    payload = complete_payload(positions: [], summary: zero_summary)
    result = with_http(stub_http(json_response(payload))) do
      fineco.fetch_portfolio_summary
    end

    assert_empty result.payload.dig("positions", "show")

    incomplete = complete_payload(positions: [], summary: SUMMARY)
    assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(incomplete))) { fineco.fetch_portfolio_summary }
    end
  end

  test "rejects blocked dossiers, absent position arrays, and mismatched summary totals" do
    blocked = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    blocked["info"]["dossier"]["blocked"] = true
    assert_raises Provider::Fineco::ReauthenticationRequired do
      with_http(stub_http(json_response(blocked))) { fineco.fetch_portfolio_summary }
    end

    missing_positions = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    missing_positions["positions"].delete("show")
    assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(missing_positions))) { fineco.fetch_portfolio_summary }
    end

    incomplete_position = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    incomplete_position["positions"]["show"][0].delete("qty")
    assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(incomplete_position))) { fineco.fetch_portfolio_summary }
    end

    partial = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    partial["summary"]["total"]["marketValue"] = 125
    assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(partial))) { fineco.fetch_portfolio_summary }
    end
  end

  test "rejects filtered snapshots even when visible monetary totals reconcile" do
    partial = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    partial["filters"]["currencies"]["total"] = %w[EUR GBP]
    partial["filters"]["currencies"]["show"] = %w[EUR]

    assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(partial))) { fineco.fetch_portfolio_summary }
    end

    invalid = complete_payload(positions: [ POSITION ], summary: SUMMARY)
    invalid["filters"]["instrumentTypes"].delete("show")
    assert_raises Provider::Fineco::InvalidResponse do
      with_http(stub_http(json_response(invalid))) { fineco.fetch_portfolio_summary }
    end
  end

  test "accepts a scoped rotated session cookie and ignores unsafe cookie scope" do
    rotated = StubResponse.new(
      code: 200,
      body: complete_payload(positions: [ POSITION ], summary: SUMMARY).to_json,
      headers: {
        "content-type" => "application/json",
        "set-cookie" => "gsessionid=rotated-session; Domain=.finecobank.com; Path=/v1/private/tol; Secure; HttpOnly"
      }
    )
    result = with_http(stub_http(rotated)) { fineco.fetch_portfolio_summary }
    assert_equal "rotated-session", result.rotated_gsessionid
    refute_includes result.inspect, "rotated-session"
    refute_includes result.inspect, "marketValue"

    unsafe = StubResponse.new(
      code: 200,
      body: complete_payload(positions: [ POSITION ], summary: SUMMARY).to_json,
      headers: {
        "set-cookie" => "gsessionid=evil-session; Domain=evil.example; Path=/; Secure"
      }
    )
    result = with_http(stub_http(unsafe)) { fineco.fetch_portfolio_summary }
    assert_nil result.rotated_gsessionid

    insecure = StubResponse.new(
      code: 200,
      body: complete_payload(positions: [ POSITION ], summary: SUMMARY).to_json,
      headers: { "set-cookie" => "gsessionid=not-secure; Domain=finecobank.com; Path=/; HttpOnly" }
    )
    result = with_http(stub_http(insecure)) { fineco.fetch_portfolio_summary }
    assert_nil result.rotated_gsessionid

    wrong_path = StubResponse.new(
      code: 200,
      body: complete_payload(positions: [ POSITION ], summary: SUMMARY).to_json,
      headers: { "set-cookie" => "gsessionid=wrong-path; Domain=finecobank.com; Path=/other; Secure" }
    )
    result = with_http(stub_http(wrong_path)) { fineco.fetch_portfolio_summary }
    assert_nil result.rotated_gsessionid
  end

  test "ignores ambiguous or expired session cookie rotations" do
    duplicate = StubResponse.new(
      code: 200,
      body: complete_payload(positions: [ POSITION ], summary: SUMMARY).to_json,
      headers: {
        "set-cookie" => [
          "gsessionid=first; Domain=finecobank.com; Path=/; Secure",
          "gsessionid=second; Domain=finecobank.com; Path=/; Secure"
        ]
      }
    )
    result = with_http(stub_http(duplicate)) { fineco.fetch_portfolio_summary }
    assert_nil result.rotated_gsessionid

    deleted = StubResponse.new(
      code: 200,
      body: complete_payload(positions: [ POSITION ], summary: SUMMARY).to_json,
      headers: {
        "set-cookie" => "gsessionid=expired; Domain=finecobank.com; Path=/; Max-Age=0; Secure"
      }
    )
    result = with_http(stub_http(deleted)) { fineco.fetch_portfolio_summary }
    assert_nil result.rotated_gsessionid
  end

  test "enforces declared and streamed body size limits" do
    declared = StubResponse.new(
      code: 200,
      headers: { "content-length" => (Provider::Fineco::MAX_BODY_BYTES + 1).to_s }
    )
    assert_raises Provider::Fineco::ResponseTooLarge do
      with_http(stub_http(declared)) { fineco.fetch_portfolio_summary }
    end

    streamed = StubResponse.new(
      code: 200,
      body: "x" * (Provider::Fineco::MAX_BODY_BYTES + 1)
    )
    assert_raises Provider::Fineco::ResponseTooLarge do
      with_http(stub_http(streamed)) { fineco.fetch_portfolio_summary }
    end

    [ 302, 503 ].each do |status|
      oversized_error_body = StubResponse.new(
        code: status,
        body: "x" * (Provider::Fineco::MAX_BODY_BYTES + 1),
        headers: { "location" => "https://evil.example/collect" }
      )
      assert_raises Provider::Fineco::ResponseTooLarge do
        with_http(stub_http(oversized_error_body)) { fineco.fetch_portfolio_summary }
      end
    end

    oversized_identity = StubResponse.new(code: 503, body: "x" * (Provider::Fineco::MAX_BODY_BYTES + 1))
    assert_raises Provider::Fineco::ResponseTooLarge do
      with_http(stub_identity_http(oversized_identity)) { fineco.fetch_portfolio_summary }
    end
  end

  test "maps network, TLS, and total timeout failures to sanitized typed errors" do
    [ Net::ReadTimeout.new, OpenSSL::SSL::SSLError.new ].each do |failure|
      error = assert_raises do
        with_http(stub_http(success_response, failure: failure)) { fineco.fetch_portfolio_summary }
      end
      assert_match(/Provider::Fineco::(RequestTimeout|RequestFailed)/, error.class.name)
      refute_includes error.message, "opaque-session"
    end

    Timeout.stub(:timeout, ->(*) { raise ::Timeout::Error, "sensitive transport detail" }) do
      error = assert_raises Provider::Fineco::RequestTimeout do
        with_http(stub_http(success_response)) { fineco.fetch_portfolio_summary }
      end
      refute_includes error.message, "sensitive transport detail"
      assert_nil error.cause
    end
  end

  test "sanitizes client inspection" do
    client = fineco
    refute_includes client.inspect, "opaque-session"
    refute_includes client.to_s, "opaque-session"
  end

  private

    def fineco
      Provider::Fineco.new(gsessionid: "opaque-session", account_index: "2", dossier_index: "11")
    end

    def with_http(http)
      Net::HTTP.stub(:new, ->(host, port, proxy) {
        assert_equal Provider::Fineco::HOST, host
        assert_equal 443, port
        assert_nil proxy
        http
      }) do
        block_given? ? yield(http) : http
      end
    end

    def stub_http(portfolio_response, identity: nil, failure: nil)
      identity_response = identity || json_response(identity_payload)
      StubHttp.new([ identity_response, portfolio_response ], failure: failure)
    end

    def stub_identity_http(identity_response, failure: nil)
      StubHttp.new([ identity_response ], failure: failure)
    end

    def success_response
      json_response(complete_payload(positions: [ POSITION ], summary: SUMMARY))
    end

    def identity_payload
      {
        "accounts" => [
          {
            "index" => 1,
            "number" => 12_345_678,
            "header" => "Synthetic account one",
            "dossiers" => [
              { "index" => 10, "number" => 10_010, "header" => "Other" }
            ]
          },
          {
            "index" => 2,
            "number" => 23_456_789,
            "header" => "Synthetic account two",
            "dossiers" => [
              {
                "index" => 11,
                "number" => 20_011,
                "type" => "investment",
                "header" => "Portfolio",
                "equityEnabled" => true,
                "fundEnabled" => true,
                "hasSubAccounts" => false,
                "tradingEnabled" => true
              }
            ]
          }
        ]
      }
    end

    def assert_identity_rejected(payload)
      http = stub_identity_http(json_response(payload))
      assert_raises Provider::Fineco::InvalidResponse do
        with_http(http) { fineco.fetch_portfolio_summary }
      end
      assert_equal 1, http.request_count
    end

    def json_response(payload, headers: {})
      StubResponse.new(
        code: 200,
        body: payload.to_json,
        headers: { "content-type" => "application/json" }.merge(headers)
      )
    end

    def complete_payload(positions:, summary:)
      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => [ "EUR" ], "show" => [ "EUR" ] },
          "instrumentTypes" => { "total" => [ "etf" ], "show" => [ "etf" ] }
        },
        "positions" => { "show" => positions.map(&:dup) },
        "summary" => { "show" => summary.dup, "total" => summary.dup }
      }
    end

    def quote_data_unavailable_payload
      position = POSITION.except(*Provider::Fineco::POSITION_MARKET_DATA_FIELDS)
      complete_payload(positions: [ position ], summary: SUMMARY)
    end

    def zero_summary
      SUMMARY.transform_values do |value|
        value.is_a?(Numeric) ? 0 : value
      end
    end
end
