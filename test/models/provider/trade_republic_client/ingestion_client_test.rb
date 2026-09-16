require "test_helper"

class Provider::TradeRepublicClient::IngestionClientTest < ActiveSupport::TestCase
  setup do
    @session = CapturedSession.new("session_blob" => '{"session":"old-cookie"}', "phone_number" => "private-phone")
    @store = mock("trusted connection credential store")
    @store.stubs(:with_session_lock).yields(@session)
    @socket = CapturedSocket.new
    @reader = Provider::TradeRepublicClient::IngestionClient.new(credential_store: @store, websocket_factory: ->(_headers) { @socket }, user_agent: "Test browser")
    @http = mock("bounded HTTP transport")
    Net::HTTP.stubs(:start).yields(@http)
  end

  test "ordinary cookie updates commit before account reads and never create refresh intent" do
    sequence = sequence("cookie persistence")
    @http.expects(:request).with { |request| request.path == "/api/v1/auth/web/session" && request["Cookie"] == "session=old-cookie" }
      .in_sequence(sequence).returns(http_response("{}", cookies: [ "session=rotated-cookie; Secure; HttpOnly" ]))
    @http.expects(:request).with do |request|
      assert_equal 1, @session.commits.size
      assert_equal "session=rotated-cookie", request["Cookie"]
      assert_equal "/api/v2/auth/account", request.path
      true
    end.in_sequence(sequence).returns(http_response('{"securitiesAccountNumber":"DE123","currency":"EUR"}'))
    assert_equal "DE123", @reader.get_account["securitiesAccountNumber"]
    assert_equal "private-phone", @session.credentials["phone_number"]
    assert_equal "rotated-cookie", JSON.parse(@session.credentials["session_blob"])["session"]
    assert_equal 2, @session.commits.size
    refute_includes @reader.inspect, "cookie"
    refute_includes @reader.inspect, "private-phone"
  end

  test "pending login blocks all financial reads" do
    @session.credentials["pending_login_state"] = "encrypted-by-boundary"
    @http.expects(:request).never
    assert_raises(Provider::TradeRepublicClient::AuthenticationRequired) { @reader.get_account }
    assert_empty @session.commits
  end

  test "an unresolved single-use refresh from another lifecycle also blocks reads" do
    @session.pending = true
    @http.expects(:request).never
    assert_raises(Provider::TradeRepublicClient::AuthenticationRequired) { @reader.get_account }
  end

  test "HTTP read timeout remains retryable without changing credential state or retrying inline" do
    @http.expects(:request).once.raises(Net::ReadTimeout.new("private-cookie"))
    error = assert_raises(Provider::TradeRepublicClient::Timeout) { @reader.get_account }
    assert_empty @session.commits
    refute @session.pending
    refute_includes error.message, "private-cookie"
    assert_nil error.cause
  end

  test "real Net HTTP startup disables transport retries before a session read times out" do
    Net::HTTP.unstub(:start)
    # Keep the real startup option setters and GET retry loop. WebMock's request
    # wrapper would bypass that loop, so replace only construction and sockets.
    http = WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP.new("api.traderepublic.com", 443, nil)
    sockets = []
    http.define_singleton_method(:connect) do
      socket = TimeoutHttpSocket.new
      sockets << socket
      instance_variable_set(:@socket, socket)
    end
    Net::HTTP.expects(:new).with("api.traderepublic.com", 443, :ENV, nil, nil, nil).once.returns(http)
    credentials = @session.credentials.deep_dup

    error = assert_raises(Provider::TradeRepublicClient::Timeout) do
      @reader.get_timeline_page(topic: "timelineTransactions")
    end

    assert_equal 0, http.max_retries
    assert_equal 1, sockets.size
    assert_equal 1, sockets.first.writes.size
    assert_match %r{\AGET /api/v1/auth/web/session HTTP/1\.1\r\n}, sockets.first.writes.first
    assert sockets.first.closed?
    refute http.started?
    assert_equal credentials, @session.credentials
    assert_empty @session.commits
    refute @session.pending
    assert_empty @socket.sent
    assert_nil error.cause
    refute_includes error.message, "private-cookie"
  end

  test "failed cookie persistence prevents use of the new session" do
    @session.fail_commit = true
    @http.expects(:request).once.returns(http_response("{}", cookies: [ "session=rotated-cookie; Secure" ]))
    assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) { @reader.get_account }
    assert_equal "old-cookie", JSON.parse(@session.credentials["session_blob"])["session"]
    refute @session.pending
  end

  test "lost credential ownership stops timeline reads before opening the socket" do
    @http.expects(:request).once.returns(http_response("{}", cookies: [ "session=rotated-cookie; Secure" ]))
    @session.expects(:persist_session_credentials!).raises(Provider::AccountData::StaleWriter.new("private ownership context"))

    error = assert_raises(Provider::AccountData::StaleWriter) do
      @reader.get_timeline_page(topic: "timelineTransactions")
    end

    assert_empty @session.commits
    assert_empty @socket.sent
    assert_equal "old-cookie", JSON.parse(@session.credentials["session_blob"])["session"]
    refute_includes error.message, "private ownership context"
    assert_nil error.cause
  end

  test "uncertain credential state retains its reauthorization requirement" do
    @http.expects(:request).once.returns(http_response("{}", cookies: [ "session=rotated-cookie; Secure" ]))
    @session.expects(:persist_session_credentials!).raises(Provider::AccountData::CredentialStore::ReauthorizationRequired.new("private refresh context"))

    error = assert_raises(Provider::AccountData::CredentialStore::ReauthorizationRequired) { @reader.get_account }

    assert_empty @session.commits
    refute_includes error.message, "private refresh context"
    assert_nil error.cause
  end

  test "session authorization WAF and rate limit failures retain safe error classes" do
    [ [ 401, "{}", Provider::TradeRepublicClient::AuthenticationRequired ],
      [ 403, '{"errorCode":"MISSING_REQUIRED_HEADER","message":"private-data"}', Provider::TradeRepublicClient::WafRequired ],
      [ 429, "{}", Provider::TradeRepublicClient::RateLimited ] ].each do |status, body, klass|
      @http.expects(:request).returns(http_response(body, code: status))
      error = assert_raises(klass) { @reader.get_account }
      refute_includes error.message, "private-data"
      assert_nil error.cause
    end
  end

  test "only explicit transient HTTP statuses receive retryable classifications" do
    [ [ 408, Provider::TradeRepublicClient::Timeout ], [ 500, Provider::TradeRepublicClient::TransientProviderError ],
      [ 502, Provider::TradeRepublicClient::TransientProviderError ], [ 503, Provider::TradeRepublicClient::TransientProviderError ],
      [ 504, Provider::TradeRepublicClient::TransientProviderError ], [ 404, Provider::TradeRepublicClient::ProviderUnavailable ],
      [ 501, Provider::TradeRepublicClient::ProviderUnavailable ] ].each do |status, klass|
      @http.expects(:request).once.returns(http_response("private response text", code: status))
      error = assert_raises(klass) { @reader.get_account }
      assert_instance_of klass, error
      assert_nil error.cause
      refute_includes error.message, "private response text"
    end
    assert_empty @session.commits
  end

  test "rate limit seconds and HTTP date survive both sanitized error boundaries" do
    freeze_time do
      [ "120", 120.seconds.from_now.httpdate ].each do |header|
        @http.expects(:request).once.returns(http_response("private rate error", code: 429, retry_after: header))
        error = assert_raises(Provider::TradeRepublicClient::RateLimited) { @reader.get_timeline_page(topic: "timelineTransactions") }
        assert_equal 120, error.retry_after
        assert_nil error.cause
        refute_includes error.message, "private rate error"
      end
    end
    assert_empty @socket.sent
    assert_empty @session.commits
  end

  test "malformed or excessive server delays decline retry rather than becoming an absent header" do
    adapter = Provider::AccountData::TradeRepublic.new(client: nil, timezone: "UTC", observed_at: Time.current)
    [ "301", "0", "-1", "NaN", "private malformed header", "1" * 129, 10.minutes.from_now.httpdate ].each do |header|
      @http.expects(:request).once.returns(http_response("{}", code: 429, retry_after: header))
      error = assert_raises(Provider::TradeRepublicClient::RateLimited) { @reader.get_timeline_page(topic: "timelineTransactions") }
      assert_equal :invalid, error.retry_after
      assert_nil adapter.activity_group_retry_delay(error: error, attempt: 0)
      assert_nil error.cause
      refute_includes error.message, header
    end
    @http.expects(:request).once.returns(http_response("{}", code: 429))
    error = assert_raises(Provider::TradeRepublicClient::RateLimited) { @reader.get_account }
    assert_nil error.retry_after
    assert_equal 15, adapter.activity_group_retry_delay(error: error, attempt: 0)
  end

  test "malformed successful HTTP payload does not become a retryable transport failure" do
    @http.expects(:request).once.returns(http_response("private invalid JSON"))
    error = assert_raises(Provider::TradeRepublicClient::MalformedResponse) { @reader.get_account }
    assert_nil error.cause
    refute_includes error.message, "private invalid JSON"
  end

  test "malformed restored cookies cannot inject request headers" do
    @session.credentials["session_blob"] = JSON.generate("session" => "value\r\nInjected:secret")
    @http.expects(:request).never
    assert_raises(Provider::TradeRepublicClient::ConfigurationError) { @reader.get_account }
  end

  test "Netscape session imports retain HttpOnly cookies from the provider domain only" do
    @session.credentials["session_blob"] = "#HttpOnly_api.traderepublic.com\tFALSE\t/\tTRUE\t0\tsession\timported-cookie\n"
    @http.expects(:request).with { |request| request["Cookie"] == "session=imported-cookie" }.twice
      .returns(http_response('{"securitiesAccountNumber":"DE123","currency":"EUR"}'))
    assert_equal "DE123", @reader.get_account["securitiesAccountNumber"]
    @session.credentials["session_blob"] = "unrelated.example\tFALSE\t/\tTRUE\t0\tsession\tother-cookie\n"
    @http.expects(:request).never
    assert_raises(Provider::TradeRepublicClient::ConfigurationError) { @reader.get_account }
  end

  test "WebSocket money is parsed directly to exact decimals and cookies never enter evidence" do
    stub_auth_reads
    @socket.messages = [ "connected", '1 A {"amount":1.234567890123456789}', '2 A {"amount":1.1}' ]
    result = @reader.get_cash
    assert_equal BigDecimal("1.234567890123456789"), result["cash"]["amount"]
    assert_equal BigDecimal("1.1"), result["available_cash"]["amount"]
    assert @socket.closed
    assert_includes @socket.sent, "unsub 1"
    assert_includes @socket.sent, "unsub 2"
    refute_includes result.inspect, "old-cookie"
  end

  test "missing optional available cash preserves the primary response" do
    stub_auth_reads
    @socket.messages = [ "connected", '1 A {"amount":"12"}', '2 E {"private":"error"}' ]
    result = @reader.get_cash
    assert_equal "12", result["cash"]["amount"]
    assert_nil result["available_cash"]
  end

  test "one timeline call consumes one named topic page and leaves continuation to the caller" do
    stub_auth_reads
    @socket.messages = [ "connected", '1 A {"items":[{"id":"event"}],"cursors":{"after":"next"}}' ]
    result = @reader.get_timeline_page(topic: "timelineActivityLog", cursor: "previous")
    assert_equal "next", result["next_cursor"]
    payload = JSON.parse(@socket.sent.find { |value| value.start_with?("sub ") }.split(" ", 3).last)
    assert_equal({ "type" => "timelineActivityLog", "after" => "previous" }, payload)
    assert @socket.closed
  end

  test "unsupported topics are rejected before authentication" do
    @http.expects(:request).never
    assert_raises(Provider::TradeRepublicClient::MalformedResponse) { @reader.get_timeline_page(topic: "accountMutation") }
  end

  test "a repeated timeline cursor or an empty continuing page cannot complete" do
    [ '{"items":[{"id":"event"}],"cursors":{"after":"same"}}', '{"items":[],"cursors":{"after":"next"}}',
      '{"items":[],"cursors":{"after":false}}' ].each do |body|
      stub_auth_reads
      @socket = CapturedSocket.new
      @socket.messages = [ "connected", "#{next_subscription_id} A #{body}" ]
      assert_raises(Provider::TradeRepublicClient::MalformedResponse) { @reader.get_timeline_page(topic: "timelineTransactions", cursor: "same") }
      assert @socket.closed
    end
  end

  test "malformed or oversized portfolio collections are not empty successful snapshots" do
    stub_auth_reads
    @socket.messages = [ "connected", '1 A {"positions":[]}' ]
    assert_raises(Provider::TradeRepublicClient::MalformedResponse) { @reader.get_portfolio }
    assert @socket.closed
  end

  test "ticker reads follow the explicit crypto exchange order and preserve raw attempts" do
    stub_auth_reads
    @socket.messages = [ "connected", '1 E {}', '2 A {"last":{"price":25.125}}' ]
    result = @reader.get_price(instrument_id: "US0378331005", category_type: "cryptos")
    assert_equal BigDecimal("25.125"), result["price"]
    assert_equal %w[BHS TUB], result["attempts"].map { |value| value["exchange"] }
    assert @socket.closed
  end

  test "delta-only subscription response cannot fabricate an uncaptured base" do
    stub_auth_reads
    @socket.messages = [ "connected", '1 D =5\t+private' ]
    error = assert_raises(Provider::TradeRepublicClient::MalformedResponse) { @reader.get_event_detail(event_id: "event-1") }
    refute_includes error.message, "private"
    assert @socket.closed
    assert_nil error.cause
  end

  test "unrelated subscription messages are bounded" do
    stub_auth_reads
    @socket.messages = [ "connected" ] + Array.new(Provider::TradeRepublicClient::IngestionClient::MAX_MESSAGES, '999 A {}')
    error = assert_raises(Provider::TradeRepublicClient::MalformedResponse) { @reader.get_event_detail(event_id: "event-1") }
    assert_nil error.cause
    assert @socket.closed
  end

  test "an actual socket receive timeout remains distinct from the message count limit" do
    stub_auth_reads
    @socket.expects(:receive).once.raises(::Timeout::Error, "private socket context")
    error = assert_raises(Provider::TradeRepublicClient::Timeout) { @reader.get_event_detail(event_id: "event-1") }
    assert_nil error.cause
    refute_includes error.message, "private socket context"
    assert @socket.closed
  end

  private
    def stub_auth_reads
      @http.expects(:request).twice.returns(http_response('{"securitiesAccountNumber":"DE123","currency":"EUR"}'))
    end

    def http_response(body, code: 200, cookies: nil, retry_after: nil)
      Struct.new(:body, :code, :cookies, :retry_after) do
        def get_fields(name)
          cookies if name == "set-cookie"
        end

        def [](name)
          retry_after if name.to_s.downcase == "retry-after"
        end
      end.new(body, code.to_s, cookies, retry_after)
    end

    def next_subscription_id
      @expected_id = @expected_id.to_i + 1
    end

    class CapturedSession
      attr_accessor :pending, :fail_commit
      attr_reader :credentials, :commits

      def initialize(values)
        @credentials, @commits, @pending = values, [], false
      end

      def refresh_pending?
        @pending
      end

      def persist_session_credentials!(values)
        raise "private commit error" if @fail_commit
        @credentials = values.deep_dup
        @commits << values.deep_dup
      end
    end

    class TimeoutHttpSocket
      attr_reader :writes

      def initialize
        @writes, @closed = [], false
      end

      def write(*values)
        @writes << values.join
        @writes.last.bytesize
      end

      def readline
        raise Net::ReadTimeout.new("private-cookie")
      end

      def closed?
        @closed
      end

      def close
        @closed = true
      end
    end

    class CapturedSocket
      attr_accessor :messages
      attr_reader :sent, :closed

      def initialize
        @sent, @messages = [], []
      end

      def send_text(value)
        @sent << value
      end

      def receive
        raise "No fake WebSocket response remains" if @messages.empty?
        @messages.shift
      end

      def close
        @closed = true
      end
    end
end
