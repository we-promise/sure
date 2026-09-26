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
    assert_equal "orderExecution", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["SAVINGS_PLAN_INVOICE_CREATED"]
    assert_equal "DIVIDEND", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["DIVIDEND"]
    assert_equal "orderExecution", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["PRIVATE_MARKET_FUND_TRADE_EXECUTED"]
    assert_equal "POC_CREATED", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["CARD_ATM_WITHDRAWAL"]
    assert_equal "POC_CREATED", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["CARD_TRANSACTION"]
    assert_equal "POC_CREATED", Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["CARD_CASH_BACK"]
    assert_nil Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["TRADING_SAVINGSPLAN_EXECUTION_FAILED"]
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

  test "advances the list cursor when only trade details remain pending" do
    @client.define_singleton_method(:collect_timeline_topic) do |_websocket, topic:, **_|
      if topic == "timelineTransactions"
        [ [ {
          "id" => "trade-1",
          "timestamp" => "2026-08-02",
          "eventType" => "TRADING_TRADE_EXECUTED",
          "category" => "orderExecution",
          "detail" => { "amount" => -100.0 }
        } ], "trade-1", [], true ]
      else
        [ [], nil, [], true ]
      end
    end
    @client.define_singleton_method(:subscribe) do |_websocket, **_|
      raise Provider::TradeRepublicClient::MalformedResponse, "no budget"
    end

    events, newest_id, warnings, complete, backfill_count = @client.send(
      :collect_all_timeline,
      Object.new,
      known_newest_event_id: nil,
      max_pages: 2,
      enrich_events: []
    )

    assert_equal [ "trade-1" ], events.map { |event| event["id"] }
    assert_equal "trade-1", newest_id
    assert complete
    assert_equal 0, backfill_count
    assert_includes warnings, "detail fetch failed for event trade-1"
  end

  test "does not mark timeline complete when pagination is truncated" do
    @client.define_singleton_method(:collect_timeline_topic) do |_websocket, topic:, **_|
      if topic == "timelineTransactions"
        [ [ { "id" => "event-1", "timestamp" => "2026-08-02" } ], "event-1", [ "timeline pagination truncated for timelineTransactions" ], false ]
      else
        [ [], nil, [], true ]
      end
    end

    _events, newest_id, warnings, complete, = @client.send(
      :collect_all_timeline,
      Object.new,
      known_newest_event_id: nil,
      max_pages: 2,
      enrich_events: []
    )

    assert_equal "event-1", newest_id
    refute complete
    assert_includes warnings, "timeline pagination truncated for timelineTransactions"
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
    @client.define_singleton_method(:subscribe) do |_websocket, *_args, **_kwargs|
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
    @client.define_singleton_method(:subscribe) do |_websocket, *_args, **_kwargs|
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

  test "falls back to average buy-in when private markets has no ticker" do
    @client.define_singleton_method(:subscribe) do |_websocket, *_args, **_kwargs|
      raise Provider::TradeRepublicClient::ProviderUnavailable
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "privateMarkets", "positions" => [
          {
            "instrumentId" => "LU3176111881",
            "name" => "Private Equity",
            "netSize" => "1.01",
            "averageBuyIn" => "100.0"
          }
        ] }
      ]
    }, sec_acc_no: "0717713602")

    assert_empty warnings
    assert_equal "100.0", positions.first["price"]
    assert_equal "cost_basis", positions.first["price_source"]
    assert_equal "private_markets", positions.first["category"]
  end

  test "prefers homeInstrumentExchange ticker before the hardcoded exchange list" do
    requested = []
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      requested << payload
      case payload[:type]
      when "homeInstrumentExchange"
        { "exchangeId" => "XETR" }
      when "ticker"
        if payload[:id] == "DE000BASF111.XETR"
          { "last" => { "price" => "45.12" } }
        else
          raise Provider::TradeRepublicClient::ProviderUnavailable
        end
      else
        {}
      end
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "stocksAndETFs", "positions" => [
          { "instrumentId" => "DE000BASF111", "name" => "BASF", "netSize" => "2" }
        ] }
      ]
    })

    assert_empty warnings
    assert_equal "45.12", positions.first["price"]
    assert requested.any? { |p| p[:type] == "homeInstrumentExchange" }
    assert requested.any? { |p| p[:type] == "ticker" && p[:id] == "DE000BASF111.XETR" }
    assert requested.none? { |p| p[:type] == "ticker" && p[:id].to_s.end_with?(".LSX") }
  end

  test "merges a privateMarketsPositions unit price when ticker feeds are empty" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      case payload[:type]
      when "privateMarketsPositions"
        {
          "positions" => [
            {
              "instrumentId" => "LU3176111881",
              "netSize" => "1.01",
              "unitPrice" => "108.50"
            }
          ]
        }
      else
        raise Provider::TradeRepublicClient::ProviderUnavailable
      end
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "privateMarkets", "positions" => [
          {
            "instrumentId" => "LU3176111881",
            "name" => "Private Equity",
            "netSize" => "1.01",
            "averageBuyIn" => "100.0"
          }
        ] }
      ]
    }, sec_acc_no: "0717713602")

    assert_empty warnings
    assert_equal "108.50", positions.first["price"]
    assert_equal "private_markets", positions.first["price_source"]
  end

  test "tolerates a rejected privateMarketsPositions subscription" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      if payload[:type] == "privateMarketsPositions"
        raise Provider::TradeRepublicClient::ProviderUnavailable, "no private markets sleeve"
      end

      raise Provider::TradeRepublicClient::ProviderUnavailable
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "privateMarkets", "positions" => [
          {
            "instrumentId" => "LU3176111881",
            "name" => "Private Equity",
            "netSize" => "1.01",
            "averageBuyIn" => "100.0"
          }
        ] }
      ]
    }, sec_acc_no: "0717713602")

    assert_empty warnings
    assert_equal "100.0", positions.first["price"]
    assert_equal "cost_basis", positions.first["price_source"]
  end

  test "maps Google Pay inbound payments to deposits" do
    assert_equal "PAYMENT_RECEIVED",
      Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES["PAYMENT_INBOUND_GOOGLE_PAY"]
    assert_equal :financial, Provider::TradeRepublicTimelineEvent.classify(
      "eventType" => "PAYMENT_INBOUND_GOOGLE_PAY",
      "title" => "Cash in"
    )
  end

  test "ignores Legal documents timeline rows without an event type" do
    assert_equal :ignored, Provider::TradeRepublicTimelineEvent.classify(
      "title" => "Legal documents",
      "subtitle" => "Accepted"
    )
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

  test "stores a real exchange symbol from the instrument subscription" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      case payload[:type]
      when "instrument"
        {
          "exchanges" => [
            { "slug" => "LSX", "symbolAtExchange" => "BAS", "active" => true },
            { "slug" => "XETR", "symbolAtExchange" => "BAS", "active" => true },
            { "slug" => "TIB", "symbolAtExchange" => "DE000BASF111", "active" => true }
          ]
        }
      when "ticker"
        { "last" => { "price" => "45.12" } }
      else
        {}
      end
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "stocksAndETFs", "positions" => [
          { "instrumentId" => "DE000BASF111", "name" => "BASF", "netSize" => "10" }
        ] }
      ]
    })

    assert_empty warnings
    assert_equal "BAS", positions.first["symbol"]
    assert_equal "XETR", positions.first["exchange_slug"]
    assert_equal "45.12", positions.first["price"]
  end

  test "ignores instrument symbols that only echo the ISIN" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      case payload[:type]
      when "instrument"
        {
          "exchanges" => [
            { "slug" => "TIB", "symbolAtExchange" => "LU3176111881", "active" => true },
            { "slug" => "LSX", "symbolAtExchange" => "LU3176111881", "active" => true }
          ]
        }
      when "ticker"
        { "last" => { "price" => "12.00" } }
      else
        {}
      end
    end

    positions, _warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "stocksAndETFs", "positions" => [
          { "instrumentId" => "LU3176111881", "name" => "ETF", "netSize" => "2" }
        ] }
      ]
    })

    assert_nil positions.first["symbol"]
    assert_nil positions.first["exchange_slug"]
    assert_equal "12.00", positions.first["price"]
  end

  test "keeps a position when the instrument subscription fails" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      if payload[:type] == "instrument"
        raise Provider::TradeRepublicClient::TransientProviderError, "instrument temporarily unavailable"
      end

      { "last" => { "price" => "99.50" } }
    end

    positions, warnings = @client.send(:normalize_positions, Object.new, {
      "categories" => [
        { "categoryType" => "stocksAndETFs", "positions" => [
          { "instrumentId" => "US0378331005", "name" => "Apple", "netSize" => "1" }
        ] }
      ]
    })

    assert_empty warnings
    assert_equal "US0378331005", positions.first["isin"]
    assert_equal "99.50", positions.first["price"]
    assert_nil positions.first["symbol"]
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

  test "normalize_event_detail parses Dutch share price and Kosten fees" do
    detail = @client.send(:normalize_event_detail, {
      "sections" => [
        { "title" => "Transactie", "data" => [
          { "title" => "Aandelen", "detail" => { "text" => "2" } },
          { "title" => "Aandelenkoers", "detail" => { "text" => "€511,96" } },
          { "title" => "Kosten", "detail" => { "text" => "€1,00" } },
          { "title" => "Totaal", "detail" => { "text" => "€1.024,92" } }
        ] },
        { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "IE00B5BMR087" } } } } ] }
      ]
    }, item: { "title" => "Core S&P 500 USD (Acc)", "subtitle" => "Kopen" })

    assert_equal "IE00B5BMR087", detail["isin"]
    assert_equal "2.0", detail["quantity"]
    assert_equal "511.96", detail["price"]
    assert_equal "1.0", detail["fees"]
    assert_equal "1024.92", detail["amount"]
  end

  test "normalize_event_detail derives buy share price from total net of fees" do
    detail = @client.send(:normalize_event_detail, {
      "sections" => [
        { "title" => "Overview", "data" => [
          { "title" => "Shares", "detail" => { "text" => "2" } },
          { "title" => "Fee", "detail" => { "text" => "€1.00" } },
          { "title" => "Total", "detail" => { "text" => "€1,024.92" } }
        ] },
        { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "IE00B5BMR087" } } } } ] }
      ]
    }, item: { "title" => "Core S&P 500", "subtitle" => "Buy" })

    assert_equal "511.96", detail["price"]
    assert_equal "1.0", detail["fees"]
  end

  test "normalize_event_detail derives sell share price from proceeds plus fees and taxes" do
    detail = @client.send(:normalize_event_detail, {
      "sections" => [
        { "title" => "Overview", "data" => [
          { "title" => "Shares", "detail" => { "text" => "2" } },
          { "title" => "Fee", "detail" => { "text" => "€1.00" } },
          { "title" => "Tax", "detail" => { "text" => "€0.50" } },
          { "title" => "Total", "detail" => { "text" => "€1,022.42" } }
        ] },
        { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "IE00B5BMR087" } } } } ] }
      ]
    }, item: { "title" => "Core S&P 500", "subtitle" => "Sell" })

    # Sell cash = gross - fee - tax → 1022.42 = 2*511.96 - 1 - 0.50
    assert_equal "-2.0", detail["quantity"]
    assert_equal "511.96", detail["price"]
    assert_equal "1.0", detail["fees"]
    assert_equal "0.5", detail["taxes"]
  end

  test "trade_detail_needs_price_backfill detects complete trades without price" do
    assert Provider::TradeRepublicClient.trade_detail_needs_price_backfill?(
      "category" => "orderExecution",
      "eventType" => "TRADING_TRADE_EXECUTED",
      "detail" => { "isin" => "IE00B5BMR087", "quantity" => "2", "amount" => "1024.92" }
    )
    refute Provider::TradeRepublicClient.trade_detail_needs_price_backfill?(
      "category" => "orderExecution",
      "eventType" => "TRADING_TRADE_EXECUTED",
      "detail" => { "isin" => "IE00B5BMR087", "quantity" => "2", "price" => "511.96" }
    )
  end

  test "card and cash events do not consume timeline detail requests" do
    requested = []
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested << payload
      { "sections" => [] }
    end

    events, = @client.send(:resolve_details, Object.new, [
      {
        "id" => "card-1",
        "timestamp" => "2026-08-01T10:00:00Z",
        "eventType" => "CARD_TRANSACTION",
        "amount" => { "value" => -12.5, "currency" => "EUR" }
      },
      {
        "id" => "transfer-1",
        "timestamp" => "2026-08-01T11:00:00Z",
        "eventType" => "PAYMENT_INBOUND",
        "amount" => { "value" => 50.0, "currency" => "EUR" }
      }
    ], nil, [])

    assert_empty requested
    assert_equal [ "card-1", "transfer-1" ], events.map { |event| event["id"] }
    assert_equal(-12.5, events.first.dig("detail", "signed_amount"))
  end

  test "trade savings saveback and round-up events request timeline details" do
    requested = []
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested << payload[:id]
      {
        "sections" => [
          { "title" => "Overview", "data" => [
            { "title" => "Shares", "detail" => { "text" => "1.5" } },
            { "title" => "Total", "detail" => { "text" => "€100.00" } }
          ] },
          { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "US0378331005" } } } } ] }
        ]
      }
    end

    items = [
      { "id" => "trade-1", "eventType" => "TRADING_TRADE_EXECUTED", "amount" => { "value" => -100.0 } },
      { "id" => "savings-1", "eventType" => "SAVINGS_PLAN_INVOICE_CREATED", "amount" => { "value" => -25.0 } },
      { "id" => "saveback-1", "eventType" => "SAVEBACK_AGGREGATE", "amount" => { "value" => -3.74 } },
      { "id" => "roundup-1", "eventType" => "SPARE_CHANGE_AGGREGATE", "amount" => { "value" => -0.40 } }
    ]

    events, = @client.send(:resolve_details, Object.new, items, nil, [])

    assert_equal %w[trade-1 savings-1 saveback-1 roundup-1], requested
    assert events.all? { |event| event.dig("detail", "isin") == "US0378331005" }
  end

  test "mixed pages prioritize reserved new details then backlog within the shared cap" do
    requested = []
    detail_response = {
      "sections" => [
        { "title" => "Overview", "data" => [
          { "title" => "Shares", "detail" => { "text" => "1" } },
          { "title" => "Total", "detail" => { "text" => "€10.00" } }
        ] },
        { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "US0378331005" } } } } ] }
      ]
    }
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested << payload[:id]
      detail_response
    end

    new_events = (Provider::TradeRepublicClient::MAX_TIMELINE_DETAILS_DELTA_RESERVED + 5).times.map do |index|
      {
        "id" => "new-#{index}",
        "timestamp" => "2026-09-0#{index % 9 + 1}T10:00:00Z",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "category" => "orderExecution",
        "detail" => { "amount" => -10.0 }
      }
    end
    backlog = 10.times.map do |index|
      {
        "id" => "old-#{index}",
        "timestamp" => "2025-01-0#{index % 9 + 1}T10:00:00Z",
        "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
        "category" => "orderExecution",
        "detail" => { "amount" => -10.0 }
      }
    end

    events, warnings, backfill_count = @client.send(
      :enrich_timeline_details,
      Object.new,
      new_events,
      enrich_events: backlog
    )

    reserved = Provider::TradeRepublicClient::MAX_TIMELINE_DETAILS_DELTA_RESERVED
    assert_equal reserved.times.map { |index| "new-#{index}" } + backlog.map { |event| event["id"] } +
      (reserved...new_events.size).map { |index| "new-#{index}" }, requested
    assert_equal backlog.size, backfill_count
    assert_empty warnings
    assert events.any? { |event| event["id"] == "old-0" && event.dig("detail", "isin") == "US0378331005" }
  end

  test "failed detail attempts consume budget without blocking later candidates" do
    requested = []
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested << payload[:id]
      raise Provider::TradeRepublicClient::MalformedResponse, "bad" if payload[:id] == "fail-1"

      {
        "sections" => [
          { "title" => "Overview", "data" => [
            { "title" => "Shares", "detail" => { "text" => "1" } },
            { "title" => "Total", "detail" => { "text" => "€10.00" } }
          ] },
          { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "US0378331005" } } } } ] }
        ]
      }
    end

    events, warnings, = @client.send(
      :enrich_timeline_details,
      Object.new,
      [
        { "id" => "fail-1", "eventType" => "TRADING_TRADE_EXECUTED", "category" => "orderExecution", "detail" => { "amount" => -1 } },
        { "id" => "ok-1", "eventType" => "TRADING_TRADE_EXECUTED", "category" => "orderExecution", "detail" => { "amount" => -1 } }
      ],
      enrich_events: []
    )

    assert_equal %w[fail-1 ok-1], requested
    assert_includes warnings, "detail fetch failed for event fail-1"
    assert_nil events.find { |event| event["id"] == "fail-1" }.dig("detail", "isin")
    assert_equal "US0378331005", events.find { |event| event["id"] == "ok-1" }.dig("detail", "isin")
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

  test "enriches stored savings-plan events with targeted timeline details" do
    requested = []
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested << payload
      {
        "sections" => [
          { "title" => "Overview", "data" => [
            { "title" => "Shares", "detail" => { "text" => "0.25" } },
            { "title" => "Total", "detail" => { "text" => "€25.00" } }
          ] },
          { "data" => [ { "detail" => { "action" => { "payload" => { "instrumentId" => "IE00B4L5Y983" } } } } ] }
        ]
      }
    end

    enriched, warnings = @client.send(
      :enrich_event_details,
      Object.new,
      [ {
        "id" => "savings-1",
        "timestamp" => "2026-06-17T10:00:00Z",
        "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
        "title" => "MSCI World",
        "detail" => { "amount" => -25.0, "currency" => "EUR" }
      } ]
    )

    assert_empty warnings
    assert_equal 1, enriched.size
    assert_equal [ { type: "timelineDetailV2", id: "savings-1" } ], requested
    assert_equal "orderExecution", enriched.first["category"]
    assert_equal "IE00B4L5Y983", enriched.first.dig("detail", "isin")
    assert_equal BigDecimal("0.25"), BigDecimal(enriched.first.dig("detail", "quantity").to_s)
  end

  test "caps targeted detail enrichment and leaves leftovers for a later sync" do
    requested_ids = []
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested_ids << payload[:id]
      {
        "sections" => [
          { "data" => [
            { "title" => "Shares", "detail" => { "text" => "1" } },
            { "detail" => { "action" => { "payload" => { "instrumentId" => "US0378331005" } } } }
          ] }
        ]
      }
    end

    max = 5
    events = (max + 3).times.map do |index|
      {
        "id" => "savings-#{index}",
        "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
        "detail" => { "amount" => -10.0 }
      }
    end

    enriched, warnings = @client.send(:enrich_event_details, Object.new, events, max: max)

    assert_equal max, enriched.size
    assert_equal max, requested_ids.size
    assert_includes warnings.first, "detail enrichment truncated"
  end

  test "detail enrichment failures become warnings while transient errors still raise" do
    calls = 0
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      calls += 1
      raise Provider::TradeRepublicClient::MalformedResponse, "bad detail" if payload[:id] == "fail-soft"
      raise Provider::TradeRepublicClient::Timeout, "timeout" if payload[:id] == "fail-hard"

      { "sections" => [] }
    end

    enriched, warnings = @client.send(
      :enrich_event_details,
      Object.new,
      [ { "id" => "fail-soft", "eventType" => "SAVINGS_PLAN_INVOICE_CREATED" } ]
    )

    assert_empty enriched
    assert_equal [ "detail fetch failed for event fail-soft" ], warnings

    assert_raises(Provider::TradeRepublicClient::Timeout) do
      @client.send(
        :enrich_event_details,
        Object.new,
        [ { "id" => "fail-hard", "eventType" => "SAVINGS_PLAN_INVOICE_CREATED" } ]
      )
    end
  end

  test "merge prefers richer detail fields over a later thin timeline copy" do
    merged = @client.send(
      :merge_enriched_events,
      [ {
        "id" => "savings-1",
        "category" => "orderExecution",
        "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
        "detail" => { "amount" => -25.0, "isin" => "IE00B4L5Y983", "quantity" => "0.25" }
      } ],
      [ {
        "id" => "savings-1",
        "category" => "orderExecution",
        "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
        "detail" => { "amount" => -25.0, "currency" => "EUR" }
      } ]
    )

    assert_equal 1, merged.size
    assert_equal "IE00B4L5Y983", merged.first.dig("detail", "isin")
    assert_equal "0.25", merged.first.dig("detail", "quantity")
    assert_equal "EUR", merged.first.dig("detail", "currency")
  end

  test "normalized events preserve lifecycle status deleted hidden and badge" do
    event = @client.send(
      :build_normalized_event,
      {
        "id" => "card-1",
        "timestamp" => "2026-09-02T10:00:00Z",
        "title" => "Coffee",
        "subtitle" => "Card payment",
        "eventType" => "CARD_TRANSACTION",
        "status" => "EXECUTED",
        "deleted" => false,
        "hidden" => true,
        "badge" => "Executed",
        "amount" => { "value" => -4.5, "currency" => "EUR" }
      },
      category: "POC_CREATED",
      detail: nil
    )

    assert_equal "EXECUTED", event["status"]
    assert_equal false, event["deleted"]
    assert_equal true, event["hidden"]
    assert_equal "Executed", event["badge"]
    assert_equal(-4.5, event.dig("detail", "amount"))
  end

  test "skeleton warnings only fire for truly unknown event types" do
    warnings = []
    @client.send(
      :build_skeleton_event,
      { "id" => "admin-1", "eventType" => "CARD_VERIFICATION", "title" => "Card verification" },
      warnings: warnings
    )
    assert_empty warnings

    @client.send(
      :build_skeleton_event,
      { "id" => "gap-1", "eventType" => "BRAND_NEW_MAPPING_GAP", "title" => "Mystery" },
      warnings: warnings
    )
    assert_equal [ "unsupported timeline event type BRAND_NEW_MAPPING_GAP" ], warnings
  end

  test "declined or deleted trade events are not treated as incomplete detail candidates" do
    declined = {
      "id" => "declined-1",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "category" => "orderExecution",
      "status" => "DECLINED",
      "detail" => { "amount" => -25.0 }
    }
    deleted = declined.merge("id" => "deleted-1", "status" => "EXECUTED", "deleted" => true)
    executed = declined.merge("id" => "ok-1", "status" => "EXECUTED", "deleted" => false)

    assert_not Provider::TradeRepublicClient.incomplete_trade_detail_event?(declined)
    assert_not Provider::TradeRepublicClient.incomplete_trade_detail_event?(deleted)
    assert Provider::TradeRepublicClient.incomplete_trade_detail_event?(executed)
  end

  test "detail enrichment skips ignored and non-importable events" do
    requested_ids = []
    @client.define_singleton_method(:subscribe) do |_websocket, **payload|
      requested_ids << payload[:id]
      { "sections" => [] }
    end

    events = [
      { "id" => "admin-1", "eventType" => "CARD_VERIFICATION", "category" => nil },
      {
        "id" => "declined-1",
        "eventType" => "CARD_TRANSACTION",
        "category" => "POC_CREATED",
        "status" => "DECLINED",
        "detail" => { "amount" => -12.0 }
      },
      {
        "id" => "trade-1",
        "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
        "category" => "orderExecution",
        "detail" => { "amount" => -25.0 }
      }
    ]

    @client.send(:enrich_timeline_details, Object.new, events, enrich_events: [])

    assert_equal [ "trade-1" ], requested_ids
  end

  test "prefer_richer_event keeps newer lifecycle fields including false booleans" do
    previous = {
      "id" => "card-1",
      "category" => "POC_CREATED",
      "status" => "AUTHORIZED",
      "deleted" => true,
      "hidden" => true,
      "detail" => { "amount" => -10.0, "isin" => "US0378331005" }
    }
    incoming = {
      "id" => "card-1",
      "category" => "POC_CREATED",
      "status" => "EXECUTED",
      "deleted" => false,
      "hidden" => false,
      "detail" => { "amount" => -10.0, "currency" => "EUR" }
    }

    merged = @client.send(:prefer_richer_event, previous, incoming)

    assert_equal "EXECUTED", merged["status"]
    assert_equal false, merged["deleted"]
    assert_equal false, merged["hidden"]
    assert_equal "US0378331005", merged.dig("detail", "isin")
    assert_equal "EUR", merged.dig("detail", "currency")
  end

  test "enrich_trade_instrument_symbols stamps sold ISINs missing from portfolio" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      if payload[:type] == "instrument" && payload[:id] == "NL0000303709"
        {
          "exchanges" => [
            { "slug" => "XETR", "symbolAtExchange" => "ABN", "active" => true }
          ]
        }
      else
        {}
      end
    end

    events = [
      {
        "id" => "sell-abn",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "category" => "orderExecution",
        "detail" => {
          "isin" => "NL0000303709",
          "quantity" => "-10",
          "amount" => "150.00",
          "currency" => "EUR"
        }
      }
    ]

    symbols = @client.send(
      :enrich_trade_instrument_symbols,
      Object.new,
      events,
      known_symbols: { "DE000BASF111" => { "symbol" => "BAS", "exchange_slug" => "XETR" } }
    )

    assert_equal "ABN", events.first.dig("detail", "symbol")
    assert_equal "XETR", events.first.dig("detail", "exchange_slug")
    assert_equal "ABN", symbols.dig("NL0000303709", "symbol")
    assert_equal "BAS", symbols.dig("DE000BASF111", "symbol")
  end

  test "enrich_trade_instrument_symbols skips known symbols and respects the lookup cap" do
    looked_up = []
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      if payload[:type] == "instrument"
        looked_up << payload[:id]
        {
          "exchanges" => [
            { "slug" => "XETR", "symbolAtExchange" => "T#{looked_up.size}", "active" => true }
          ]
        }
      else
        {}
      end
    end

    known = { "HELD001" => { "symbol" => "HOLD", "exchange_slug" => "XETR" } }
    events = ([
      {
        "id" => "held-trade",
        "category" => "orderExecution",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "detail" => { "isin" => "HELD001", "quantity" => "1", "amount" => "10" }
      }
    ] + (1..3).map do |i|
      {
        "id" => "sold-#{i}",
        "category" => "orderExecution",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "detail" => { "isin" => "SOLD#{i}", "quantity" => "-1", "amount" => "10" }
      }
    end)

    stub_const = Provider::TradeRepublicClient.const_get(:MAX_INSTRUMENT_LOOKUPS)
    Provider::TradeRepublicClient.send(:remove_const, :MAX_INSTRUMENT_LOOKUPS)
    Provider::TradeRepublicClient.const_set(:MAX_INSTRUMENT_LOOKUPS, 2)

    begin
      symbols = @client.send(:enrich_trade_instrument_symbols, Object.new, events, known_symbols: known)
    ensure
      Provider::TradeRepublicClient.send(:remove_const, :MAX_INSTRUMENT_LOOKUPS)
      Provider::TradeRepublicClient.const_set(:MAX_INSTRUMENT_LOOKUPS, stub_const)
    end

    assert_equal [ "SOLD1", "SOLD2" ], looked_up
    refute_includes looked_up, "HELD001"
    assert_equal "HOLD", symbols.dig("HELD001", "symbol")
    assert_equal "T1", symbols.dig("SOLD1", "symbol")
    assert_equal "T2", symbols.dig("SOLD2", "symbol")
    assert_nil symbols["SOLD3"]
    assert_nil events.find { |e| e["id"] == "sold-3" }.dig("detail", "symbol")
  end

  test "enrich_trade_instrument_symbols ignores ISIN-echo symbols and failed lookups" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      case payload[:id]
      when "ECHO001"
        {
          "exchanges" => [
            { "slug" => "TIB", "symbolAtExchange" => "ECHO001", "active" => true }
          ]
        }
      when "FAIL001"
        raise Provider::TradeRepublicClient::ProviderUnavailable, "instrument unavailable"
      else
        {}
      end
    end

    events = [
      {
        "id" => "echo",
        "category" => "orderExecution",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "detail" => { "isin" => "ECHO001", "quantity" => "-1", "amount" => "10" }
      },
      {
        "id" => "fail",
        "category" => "orderExecution",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "detail" => { "isin" => "FAIL001", "quantity" => "-1", "amount" => "10" }
      }
    ]

    symbols = @client.send(:enrich_trade_instrument_symbols, Object.new, events, known_symbols: {})

    assert_empty symbols
    assert_nil events.first.dig("detail", "symbol")
    assert_nil events.last.dig("detail", "symbol")
  end

  test "enrich_trade_instrument_symbols looks up stored ISINs absent from the delta events" do
    @client.define_singleton_method(:subscribe) do |_websocket, *args, **kwargs|
      payload = (args.first || kwargs).with_indifferent_access
      if payload[:type] == "instrument" && payload[:id] == "NL0000303709"
        {
          "exchanges" => [
            { "slug" => "XETR", "symbolAtExchange" => "ABN", "active" => true }
          ]
        }
      else
        {}
      end
    end

    symbols = @client.send(
      :enrich_trade_instrument_symbols,
      Object.new,
      [],
      known_symbols: {},
      extra_isins: [ "NL0000303709" ]
    )

    assert_equal "ABN", symbols.dig("NL0000303709", "symbol")
    assert_equal "XETR", symbols.dig("NL0000303709", "exchange_slug")
  end
end
