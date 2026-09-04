require "test_helper"

class TradeRepublicClientTest < ActiveSupport::TestCase
  setup do
    @client = Provider::TradeRepublicClient.new(phone_number: "+491701234567", pin: "1234")
  end

  test "authentication requires a transient PIN" do
    client = Provider::TradeRepublicClient.new(phone_number: "+491701234567")

    assert_raises(Provider::TradeRepublicClient::ConfigurationError) do
      client.initiate_login
    end
  end

  test "sync requires an encrypted session blob" do
    assert_raises(Provider::TradeRepublicClient::ConfigurationError) do
      @client.sync(session_txt: nil)
    end
  end

  test "authenticated login rejects an account without a securities account number" do
    response_class = Struct.new(:code, :body) do
      def is_a?(klass)
        return true if klass == Net::HTTPSuccess

        super
      end
    end
    session = mock
    session.stubs(:login_headers).returns({})
    session.expects(:get).with("/api/v2/auth/account", headers: {}).returns(
      response_class.new("200", { "currency" => "EUR" }.to_json)
    )

    error = assert_raises(Provider::TradeRepublicClient::MalformedResponse) do
      @client.send(:authenticated_session_result, session)
    end

    assert_match(/securities account number/i, error.message)
  end

  test "reconstructs Trade Republic delta websocket payloads" do
    previous = '{"items":[1,2,3]}'
    delta = "=15\t+%2C4%5D%7D"

    assert_equal '{"items":[1,2,3,4]}', @client.send(:apply_delta, previous, delta)
  end

  test "rejects a delta without a base response" do
    assert_raises(Provider::TradeRepublicClient::MalformedResponse) do
      @client.send(:apply_delta, nil, "=2")
    end
  end

  test "extracts provider error codes from both supported response shapes" do
    response = Struct.new(:body)
    top_level = response.new('{"errorCode":"MISSING_REQUIRED_HEADER"}')
    nested = response.new('{"errors":[{"errorCode":"AUTHENTICATION_ERROR"}]}')

    assert_equal "MISSING_REQUIRED_HEADER", @client.send(:response_error_code, top_level)
    assert_equal "AUTHENTICATION_ERROR", @client.send(:response_error_code, nested)
  end

  test "surfaces WAF failures as an actionable provider error" do
    response = Struct.new(:body, :code).new('{"errorCode":"MISSING_REQUIRED_HEADER"}', "400")

    assert_raises(Provider::TradeRepublicClient::WafRequired) do
      @client.send(:raise_http_error, response)
    end
  end

  test "normalizes current timeline event types to import categories" do
    assert_equal "orderExecution", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["TRADING_TRADE_EXECUTED"]
    assert_equal "orderExecution", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["TRADE_INVOICE"]
    assert_equal "DIVIDEND", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["DIVIDEND"]
    assert_equal "orderExecution", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["PRIVATE_MARKET_FUND_TRADE_EXECUTED"]
    assert_equal "POC_CREATED", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["CARD_ATM_WITHDRAWAL"]
    assert_equal "POC_CREATED", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["CARD_TRANSACTION"]
    assert_equal "POC_CREATED", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["CARD_CASH_BACK"]
  end

  test "merges transaction and activity timelines without duplicate events" do
    responses = {
      "timelineTransactions" => [ [ { "id" => "cash-1", "timestamp" => "2026-08-02" } ], "cash-1", [], true ],
      "timelineActivityLog" => [ [ { "id" => "cash-1", "timestamp" => "2026-08-02" }, { "id" => "trade-1", "timestamp" => "2026-08-03" } ], "trade-1", [], true ]
    }
    @client.define_singleton_method(:collect_timeline_topic) do |_websocket, topic:, **_|
      responses.fetch(topic)
    end

    events, newest_id, warnings = @client.send(:collect_all_timeline, Object.new, known_newest_event_id: nil, max_pages: 2)

    assert_equal %w[cash-1 trade-1], events.map { |event| event["id"] }
    assert_equal "trade-1", newest_id
    assert_empty warnings
  end

  test "does not advance the cursor when timeline details are incomplete" do
    @client.define_singleton_method(:collect_timeline_topic) do |_websocket, topic:, **_|
      if topic == "timelineTransactions"
        [ [ { "id" => "event-1", "timestamp" => "2026-08-02" } ], nil, [], true ]
      else
        [ [], nil, [], true ]
      end
    end

    events, newest_id, warnings, complete = @client.send(:collect_all_timeline, Object.new, known_newest_event_id: nil, max_pages: 2)

    assert_equal [ "event-1" ], events.map { |event| event["id"] }
    assert_nil newest_id
    assert_empty warnings
    refute complete
  end

  test "recognizes QR login pending state" do
    pending = { "challenge_id" => "challenge-1", "session_blob" => "session=1", "expires_at" => 1.minute.from_now.iso8601 }
    encoded = Base64.strict_encode64(JSON.generate(pending))

    assert @client.qr_login?(pending_login_b64: encoded)
    assert_equal "qr_pending", @client.login_stage(pending_login_b64: encoded)
  end

  test "rotates the QR payload and token expiry while polling" do
    response_class = Struct.new(:code, :body) do
      def is_a?(klass)
        return true if klass == Net::HTTPSuccess

        super
      end
    end
    session = mock
    session.stubs(:login_headers).returns({})
    session.expects(:get).with(regexp_matches(%r{/qr-challenges/}), headers: {}).returns(
      response_class.new("200", {
        "status" => "PENDING",
        "qrCodePayload" => "https://trade-republic.example/rotated-token",
        "qrCodeTokenExpiresAt" => 10.seconds.from_now.iso8601
      }.to_json)
    )
    @client.define_singleton_method(:new_session) { |session_blob:| session }

    pending = {
      "challenge_id" => "challenge-1",
      "session_blob" => "session=1",
      "expires_at" => 1.minute.from_now.iso8601,
      "qr_code_payload" => "https://trade-republic.example/old-token",
      "qr_code_token_expires_at" => 1.second.ago.iso8601
    }

    result = @client.poll_qr_login(pending_login_b64: Base64.strict_encode64(JSON.generate(pending)))
    next_pending = JSON.parse(Base64.strict_decode64(result.data.fetch("pending_login_b64")))

    assert_equal "https://trade-republic.example/rotated-token", result.data["qr_code_payload"]
    assert_equal next_pending["qr_code_token_expires_at"], result.data["qr_code_token_expires_at"]
    assert_equal "https://trade-republic.example/rotated-token", next_pending["qr_code_payload"]
  end

  test "recognizes Trade Republic approval states from state or status" do
    %w[APPROVED CONFIRMED COMPLETED SUCCESS OK DONE].each do |state|
      assert @client.send(:login_process_completed?, { "state" => state })
      assert @client.send(:login_process_completed?, { "status" => state })
    end

    assert @client.send(:login_process_completed?, { "state" => "pending", "status" => "approved" })
    assert @client.send(:login_process_completed?, { "statusCode" => "completed" })
    refute @client.send(:login_process_completed?, { "state" => "PENDING" })
  end

  test "extracts cash from nested money payloads" do
    payload = { "cash" => { "available" => { "value" => "123.45", "currency" => "EUR" } } }

    assert_equal "123.45", @client.send(:money_amount, payload).to_s
    assert_equal "EUR", @client.send(:money_currency, payload)
  end

  test "keeps positions when Trade Republic has no supported ticker price" do
    @client.define_singleton_method(:subscribe) do |_websocket, payload|
      raise Provider::TradeRepublicClient::ProviderUnavailable if payload[:id].end_with?(".LSX")

      { "last" => { "price" => "250.00" } }
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "cryptos", "positions" => [
          { "instrumentId" => "XF000BTC0017", "name" => "Bitcoin", "netSize" => "0.1" }
        ] }
      ]
    })

    assert_equal "crypto_wallet", positions.first["category"]
    assert_equal "250.00", positions.first["price"]
    assert_empty warnings
  end

  test "preserves an unpriced position for category visibility" do
    @client.define_singleton_method(:subscribe) do |_websocket, **_payload|
      raise Provider::TradeRepublicClient::ProviderUnavailable
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "cryptos", "positions" => [
          { "instrumentId" => "XF000ETH0019", "name" => "Ethereum", "netSize" => "1.5" }
        ] }
      ]
    })

    assert_equal({
      "isin" => "XF000ETH0019",
      "name" => "Ethereum",
      "category" => "crypto_wallet",
      "quantity" => "1.5"
    }, positions.first)
    assert_equal [ "price unavailable for XF000ETH0019; position kept without valuation" ], warnings
  end

  test "preserves a position when a ticker subscription times out" do
    @client.define_singleton_method(:subscribe) do |_websocket, **_payload|
      raise Provider::TradeRepublicClient::Timeout, "ticker did not answer"
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "stocksAndETFs", "positions" => [
          { "instrumentId" => "LU3176111881", "name" => "ETF", "netSize" => "2.25" }
        ] }
      ]
    })

    assert_equal "2.25", positions.first["quantity"]
    assert_nil positions.first["price"]
    assert_equal [ "price unavailable for LU3176111881; position kept without valuation" ], warnings
  end

  test "marks a snapshot partial when malformed positions are skipped" do
    @client.expects(:position_price).never

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "stocksAndETFs", "positions" => [
          { "name" => "Missing identity", "netSize" => "2" },
          { "instrumentId" => "US0378331005", "name" => "Missing quantity" }
        ] }
      ]
    })

    assert_empty positions
    assert_equal [
      "malformed portfolio position skipped: missing instrument ID",
      "malformed portfolio position skipped: missing quantity"
    ], warnings
  end

  test "resolves event type and preserves the signed timeline amount" do
    @client.define_singleton_method(:subscribe) do |_websocket, **_payload|
      {
        "sections" => [
          { "title" => "Overview", "data" => [
            { "title" => "Shares", "detail" => { "text" => "1.5" } },
            { "title" => "Total", "detail" => { "text" => "€100.00" } }
          ] },
          { "title" => "Asset", "data" => [
            { "title" => "Apple", "detail" => { "text" => "Apple" } }
          ] },
          { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "US0378331005" } } } } ] }
        ]
      }
    end

    events, = @client.send(:resolve_details, Object.new, [
      {
        "id" => "evt-1",
        "timestamp" => "2026-08-01T10:00:00Z",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "amount" => { "value" => -100.0, "currency" => "EUR" }
      }
    ], nil, [])

    assert_equal "orderExecution", events.first["category"]
    assert_equal(-100.0, events.first.dig("detail", "signed_amount"))
  end

  test "rejects an expired pending login state" do
    pending = {
      "process_id" => "process-1",
      "session_blob" => "session=1",
      "expires_at" => 1.minute.ago.iso8601
    }
    encoded = Base64.strict_encode64(JSON.generate(pending))

    assert_raises(Provider::TradeRepublicClient::LoginExpired) do
      @client.send(:decode_pending, encoded)
    end
  end

  test "does not collapse distinct timeline events that have no id" do
    responses = {
      "timelineTransactions" => [
        [
          { "timestamp" => "2026-08-02T10:00:00Z", "eventType" => "CARD_TRANSACTION" },
          { "timestamp" => "2026-08-02T11:00:00Z", "eventType" => "CARD_TRANSACTION" }
        ],
        nil,
        []
      ],
      "timelineActivityLog" => [ [], nil, [] ]
    }
    @client.define_singleton_method(:collect_timeline_topic) do |_websocket, topic:, **_|
      responses.fetch(topic)
    end

    events, = @client.send(:collect_all_timeline, Object.new, known_newest_event_id: nil, max_pages: 1)

    assert_equal 2, events.size
  end

  test "keeps the page containing the cursor as an overlap window" do
    @client.define_singleton_method(:subscribe) do |_websocket, payload|
      if payload[:type] == "timelineTransactions"
        { "items" => [ { "id" => "new", "timestamp" => "2026-08-03" }, { "id" => "old", "timestamp" => "2026-08-02" } ], "cursors" => { "after" => "next-page" } }
      else
        { "items" => [], "cursors" => {} }
      end
    end

    events, = @client.send(:collect_all_timeline, Object.new, known_newest_event_id: "old", max_pages: 2)

    assert_equal %w[new old], events.map { |event| event["id"] }
  end

  test "retries a network timeout with bounded backoff" do
    attempts = 0
    @client.stubs(:sleep_for)
    @client.define_singleton_method(:sync_once) do |**_|
      attempts += 1
      raise Provider::TradeRepublicClient::Timeout, "timeout" if attempts == 1

      :ok
    end

    assert_equal :ok, @client.sync(session_txt: "session")
    assert_equal 2, attempts
  end

  test "uses Retry-After for a bounded rate-limit retry" do
    attempts = 0
    sleeps = []
    @client.define_singleton_method(:sleep_for) { |seconds| sleeps << seconds }
    @client.define_singleton_method(:sync_once) do |**_|
      attempts += 1
      raise Provider::TradeRepublicClient::RateLimited.new("rate limited", retry_after: 1.25) if attempts == 1

      :ok
    end

    assert_equal :ok, @client.sync(session_txt: "session")
    assert_equal [ 1.25 ], sleeps
  end

  test "does not retry expired sessions or malformed payloads" do
    [ Provider::TradeRepublicClient::AuthenticationRequired, Provider::TradeRepublicClient::MalformedResponse ].each do |error_class|
      attempts = 0
      @client.define_singleton_method(:sleep_for) { |_seconds| flunk "unexpected retry" }
      @client.define_singleton_method(:sync_once) do |**_|
        attempts += 1
        raise error_class, "fatal"
      end

      assert_raises(error_class) { @client.sync(session_txt: "session") }
      assert_equal 1, attempts
    end
  end

  test "rejects malformed QR login state" do
    assert_raises(Provider::TradeRepublicClient::InvalidChallenge) do
      @client.send(:decode_qr_pending, "not-base64")
    end
  end

  test "rejects expired QR login state" do
    pending = {
      "challenge_id" => "challenge-1",
      "session_blob" => "session=1",
      "expires_at" => 1.minute.ago.iso8601
    }
    encoded = Base64.strict_encode64(JSON.generate(pending))

    assert_raises(Provider::TradeRepublicClient::LoginExpired) do
      @client.send(:decode_qr_pending, encoded)
    end
  end

  test "classifies an already processed QR token as expired" do
    response = Struct.new(:code, :body).new(
      "409",
      { "errors" => [ { "errorCode" => "ALREADY_PROCESSED" } ] }.to_json
    )

    assert_raises(Provider::TradeRepublicClient::LoginExpired) do
      @client.send(:raise_login_error, response)
    end
  end
end
