require "test_helper"

class Provider::DirectaTest < ActiveSupport::TestCase
  test "parses documented Italian liquidity signs and rejects malformed grouping" do
    assert_equal BigDecimal("-1234.56"), Provider::Directa.parse_cash_amount("1.234,56-")
    assert_equal BigDecimal("1234.56"), Provider::Directa.parse_cash_amount("1.234,56")
    assert_equal BigDecimal("-12.5"), Provider::Directa.parse_cash_amount("-12,50")
    assert_nil Provider::Directa.parse_cash_amount("1.2.3")
    assert_nil Provider::Directa.parse_cash_amount("--12,50")
    assert_nil Provider::Directa.parse_cash_amount("-12,50-")
  end

  test "returns an OTP challenge without retaining the caller password" do
    http = FakeHttpTransport.new(
      response(:login, "{\"USER\":\"OTP_challenge-secret\"}")
    )
    client = Provider::Directa.new(http_transport: http)
    password = "correct horse battery staple".freeze

    result = client.begin_login(account_number: "X12", password: password, connection_generation: 3)

    assert_instance_of Provider::Directa::LoginChallenge, result
    assert_equal "X12", result.account_number
    assert_equal 3, result.connection_generation
    assert_equal "challenge-secret", result.challenge_token
    assert_equal "correct horse battery staple", password
    request = http.calls.fetch(0).fetch(:options)
    assert_equal :login, http.calls.fetch(0).fetch(:operation)
    assert_equal [ [ "USER", "00X12" ], [ "PASSW", "correct horse battery staple" ], [ "FUNZI", "JHTJ" ] ], request.fetch(:form)
    refute_includes result.inspect, "challenge-secret"
    refute_includes result.as_json.to_s, "challenge-secret"
  end

  test "accepts a success line after other response lines and verifies both account identities" do
    initial_token = "abcdefgh12345678abcdefgh12345678"
    http = FakeHttpTransport.new(
      response(:login, "status\r\nUSER__#{initial_token}\r\n"),
      response(:account_identity, "X12\r\n"),
      response(:startup_metadata, "{\"userInfo\":{\"conto\":\"00X12\"}}")
    )
    client = Provider::Directa.new(http_transport: http)
    otp_code = "104233".freeze

    result = client.complete_login(
      account_number: "00X12",
      challenge_token: "original-challenge",
      otp_code: otp_code,
      connection_generation: 4
    )

    multi_token = "8#{initial_token[1]}9#{initial_token[3..]}"
    assert_instance_of Provider::Directa::VerifiedSession, result
    assert_equal "00X12", result.account_number
    assert_equal "00X12", result.account_identity
    assert_equal multi_token, result.multi_token
    assert_equal "4#{multi_token[1..]}", result.mono_token
    assert_equal Provider::Directa::HOST, result.host
    assert_equal 4, result.connection_generation
    assert_equal "104233", otp_code
    submitted_form = http.calls.fetch(0).fetch(:options).fetch(:form)
    assert_equal "original-challenge", submitted_form.find { |key, _| key == "PASSW" }.last
    assert_equal "104233", submitted_form.find { |key, _| key == "FILL6" }.last
    assert_equal({ "USER" => multi_token }, http.calls.fetch(1).fetch(:options).fetch(:query))
    assert_equal({ "REQUEST" => "*", "TOKEN" => multi_token }, http.calls.fetch(2).fetch(:options).fetch(:query))
  end

  test "returns the existing typed challenge after a rejected OTP response" do
    http = FakeHttpTransport.new(response(:login, "{\"ERROR\":\"invalid OTP\"}"))
    client = Provider::Directa.new(http_transport: http)
    otp_code = "104233"

    result = client.complete_login(
      account_number: "00123",
      challenge_token: "same-challenge",
      otp_code: otp_code,
      connection_generation: 4
    )

    assert_instance_of Provider::Directa::LoginChallenge, result
    assert_equal "same-challenge", result.challenge_token
    assert_equal "00123", result.account_number
    assert_equal 4, result.connection_generation
    assert_equal "104233", otp_code
  end

  test "does not create a verified session when bootstrap identity disagrees" do
    initial_token = "abcdefgh12345678abcdefgh12345678"
    http = FakeHttpTransport.new(
      response(:login, "USER__#{initial_token}"),
      response(:account_identity, "99999")
    )
    client = Provider::Directa.new(http_transport: http)

    error = assert_raises(Provider::Directa::AccountIdentityMismatch) do
      client.begin_login(account_number: "123", password: "not-persisted", connection_generation: 1)
    end

    assert_equal :account_identity_changed, error.failure_code
    assert_nil error.cause
    refute_includes error.message, "99999"
    refute_includes error.inspect, "not-persisted"
  end

  test "rejects unsafe account codes before making HTTP requests" do
    http = FakeHttpTransport.new
    client = Provider::Directa.new(http_transport: http)

    [ "X12&USER=9", "X12\r\n", "Xé123", "X" * 33 ].each do |account|
      assert_raises(Provider::Directa::ConfigurationError) do
        client.begin_login(account_number: account, password: "synthetic-password", connection_generation: 1)
      end
    end

    assert_empty http.calls
  end

  test "alphanumeric identities keep letters and embedded zeros significant in both bootstrap responses" do
    token = "abcdefgh12345678abcdefgh12345678"
    [ "Y0123", "X123", "x0123", "0X0123" ].each do |other_account|
      [ :account_identity, :startup_metadata ].each do |mismatched_operation|
        http = FakeHttpTransport.new(
          response(:login, "USER__#{token}"),
          response(:account_identity, mismatched_operation == :account_identity ? other_account : "X0123"),
          response(:startup_metadata, { userInfo: { conto: mismatched_operation == :startup_metadata ? other_account : "X0123" } }.to_json)
        )

        assert_raises(Provider::Directa::AccountIdentityMismatch) do
          Provider::Directa.new(http_transport: http).begin_login(
            account_number: "X0123", password: "synthetic-password", connection_generation: 1
          )
        end
      end
    end
  end

  test "reads only cash and the completed positions photo before optionally enriching instruments" do
    session = verified_session
    stream = FakeTradingTransport.new([
      "1;0;0;0;#{session.multi_token};\r\n",
      "2;7;0;;;UNIV-1;;;0;5;12.5\r\n",
      "3;6;0;10;;20;;1.234,56;99;30\r\n",
      "4;7;9\r\n"
    ])
    http = FakeHttpTransport.new(
      response(:instrument_metadata, {
        titoli: [
          {
            CodiceRichiesto: "UNIV-1",
            Codice: "AAPL",
            Isin: "US0378331005",
            Divisa: "USD",
            Descriz: "Apple",
            MercNeg: "NASDAQ",
            Moltip: "1"
          }
        ]
      }.to_json)
    )
    client = Provider::Directa.new(
      session: session,
      http_transport: http,
      trading_connection_factory: lambda { |verified_session:|
        Provider::Directa::TradingConnection.new(
          session: verified_session,
          transport_factory: ->(deadline:) { stream }
        )
      }
    )

    snapshot = client.fetch_portfolio_snapshot
    position = snapshot.positions.fetch(0)

    assert snapshot.complete?
    assert snapshot.cash_seen
    assert snapshot.positions_complete
    refute snapshot.full_photo_complete
    assert_equal BigDecimal("1234.56"), snapshot.cash.amount
    assert_equal "EUR", snapshot.cash.currency
    assert_equal :verified, snapshot.cash.currency_status
    assert_equal "US0378331005", position.instrument_metadata.isin
    assert_equal "USD", position.instrument_metadata.currency
    assert_nil position.instrument_metadata.mic
    assert_equal :partial, position.identity_status
    assert_equal :unavailable, position.valuation_status
    assert_nil position.valuation_date
    assert_nil position.market_value
    assert_equal [ "21#{session.multi_token}ND\r\n", "70\r\n" ], stream.writes
    assert stream.closed
    query = http.calls.fetch(0).fetch(:options).fetch(:query)
    assert_equal "Y", query.fetch("JSON")
    assert_equal "Y", query.fetch("CODPREZZI")
    assert_equal session.multi_token, query.fetch("TOKEN")
    assert_equal "UNIV-1", query.fetch("TITOLI")
    assert_equal "*ALL", query.fetch("ATTRIBUTI")
  end

  test "rejects a sequence gap and never sends a trading command" do
    session = verified_session
    stream = FakeTradingTransport.new([
      "1;0;0;0;#{session.multi_token};",
      "2;6;0;10;;20;;100,00;0;30",
      "4;7;9"
    ])
    client = Provider::Directa.new(
      session: session,
      trading_connection_factory: lambda { |verified_session:|
        Provider::Directa::TradingConnection.new(
          session: verified_session,
          transport_factory: ->(deadline:) { stream }
        )
      }
    )

    error = assert_raises(Provider::Directa::SequenceError) do
      client.fetch_portfolio_snapshot
    end

    assert_equal :sequence_mismatch, error.failure_code
    assert_equal [ "21#{session.multi_token}ND\r\n", "70\r\n" ], stream.writes
    assert stream.closed
  end

  test "marks an expired trading token for reauthentication" do
    session = verified_session
    stream = FakeTradingTransport.new([
      "1;0;0;0;#{session.multi_token};",
      "2;9;3;expired"
    ])
    client = Provider::Directa.new(
      session: session,
      trading_connection_factory: lambda { |verified_session:|
        Provider::Directa::TradingConnection.new(
          session: verified_session,
          transport_factory: ->(deadline:) { stream }
        )
      }
    )

    error = assert_raises(Provider::Directa::AuthenticationError) do
      client.fetch_portfolio_snapshot
    end

    assert_equal :session_expired, error.failure_code
    assert_equal [ "21#{session.multi_token}ND\r\n", "70\r\n" ], stream.writes
  end

  test "reads TLS data already buffered inside the SSL socket" do
    socket = Class.new do
      def pending
        1
      end

      def read_nonblock(_size)
        "buffered line\n"
      end
    end.new
    transport = Provider::Directa::TradingConnection::TlsTransport.allocate
    transport.instance_variable_set(:@buffer, +"".b)
    transport.instance_variable_set(:@socket, socket)

    assert_equal "buffered line", transport.read_line(timeout: 0.1)
  end

  test "bounds TLS DNS resolution by the remaining operation deadline" do
    resolver_calls = Queue.new
    socket_options = Queue.new
    original_socket_tcp = Socket.method(:tcp)
    observed_socket_tcp = lambda do |*arguments, **options|
      socket_options << options
      original_socket_tcp.call(*arguments, **options)
    end
    slow_resolver = lambda do |*arguments, **options|
      resolver_calls << arguments
      sleep 0.4
      raise SocketError, "synthetic resolver delay"
    end
    budget = 0.05
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = Addrinfo.stub(:getaddrinfo, slow_resolver) do
      Socket.stub(:tcp, observed_socket_tcp) do
        assert_raises(Provider::Directa::TradingConnection::RequestTimeout) do
          Provider::Directa::TradingConnection::TlsTransport.new(deadline: started_at + budget)
        end
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator resolver_calls.size, :>, 0
    assert_equal 1, socket_options.size
    options = socket_options.pop
    assert_operator options.fetch(:resolv_timeout), :<=, budget
    assert_operator options.fetch(:connect_timeout), :<=, budget
    assert_operator options.fetch(:resolv_timeout), :>, 0
    assert_operator options.fetch(:connect_timeout), :>, 0
    assert_operator elapsed, :<, 0.2
    assert_nil error.cause
  end

  test "sends only one unanswered heartbeat before the fourteen second deadline" do
    session = verified_session
    now = 0.0
    lines = [ "1;0;0;0;#{session.multi_token};" ]
    writes = []
    transport = Object.new
    transport.define_singleton_method(:write) { |value, deadline:| writes << value.dup }
    transport.define_singleton_method(:read_line) do |timeout:|
      line = lines.shift
      if line
        line
      else
        now += timeout
        nil
      end
    end
    transport.define_singleton_method(:close) { }
    connection = Provider::Directa::TradingConnection.new(
      session: session,
      clock: -> { now },
      transport_factory: ->(deadline:) { transport }
    )

    assert_raises(Provider::Directa::TradingConnection::RequestTimeout) do
      connection.fetch_snapshot(deadline: 25.0)
    end

    assert_equal [ "21#{session.multi_token}ND\r\n", "70\r\n", "40\r\n" ], writes
  end

  test "HTTP transport rejects operations outside its fixed endpoint allowlist" do
    transport = Provider::Directa::HttpTransport.new

    error = assert_raises(Provider::Directa::ConfigurationError) do
      transport.request(:logout, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1, body_limit: 1024)
    end

    assert_equal :request_not_allowed, error.failure_code
  end

  private

    def response(operation, body)
      FakeResponse.new(operation: operation, response: Provider::Directa::HttpTransport::Response.new(status: 200, body: body))
    end

    def verified_session
      token = "abcdefgh12345678abcdefgh12345678"
      multi_token = "8#{token[1]}9#{token[3..]}"
      Provider::Directa::VerifiedSession.new(
        account_number: "00123",
        account_identity: "123",
        multi_token: multi_token,
        mono_token: "4#{multi_token[1..]}",
        host: Provider::Directa::HOST,
        connection_generation: 1
      )
    end

    FakeResponse = Struct.new(:operation, :response, keyword_init: true)

    class FakeHttpTransport
      attr_reader :calls

      def initialize(*responses)
        @responses = responses
        @calls = []
      end

      def request(operation, **options)
        @calls << { operation: operation, options: options.transform_values { |value| duplicate(value) } }
        response = @responses.shift
        raise "unexpected Directa HTTP request" unless response&.operation == operation

        response.response
      end

      private

        def duplicate(value)
          case value
          when Array
            value.map { |item| duplicate(item) }
          when Hash
            value.transform_values { |item| duplicate(item) }
          when String
            value.dup
          else
            value
          end
        end
    end

    class FakeTradingTransport
      attr_reader :writes

      def initialize(lines)
        @lines = lines
        @writes = []
        @closed = false
      end

      def write(value, deadline:)
        @writes << value.dup
      end

      def read_line(timeout:)
        @lines.shift&.sub(/\r?\n\z/, "")
      end

      def close
        @closed = true
      end

      def closed
        @closed
      end

      alias closed? closed
    end
end
