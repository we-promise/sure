require "test_helper"

class Provider::Directa::HistoryTest < ActiveSupport::TestCase
  test "keeps fetching short pages until Directa returns an empty order sentinel" do
    responses = identity_responses + [
      response(:executed_orders, { "ORDER" => [ order_row(1, "00000000000001", event_date: 20260503, entry_date: 20260430), order_row(2, "00000000000002", event_date: 20260505) ] }),
      response(:executed_orders, { "ORDER" => [ order_row(3, "00000000000003", event_date: 20260507) ] }),
      response(:executed_orders, { "ORDER" => [] })
    ] + identity_responses
    http = FakeHttpTransport.new(*responses)

    result = history(http).fetch_orders(date_from: Date.new(2026, 5, 1), date_to: Date.new(2026, 5, 31))

    assert result.complete
    assert_equal [ "00000000000001", "00000000000002", "00000000000003" ], result.orders.map { |row| row.fetch("Riferimento") }
    assert_equal [ Date.new(2026, 5, 1), Date.new(2026, 5, 31) ], [ result.date_from, result.date_to ]
    assert_equal "00123", result.scope.account_number
    assert_equal "123", result.scope.account_identity
    assert_equal 7, result.scope.connection_generation
    assert_equal [ 0, 2, 3 ], order_queries(http).map { |query| query.fetch("RCDDA").to_i }
    assert order_queries(http).all? { |query| query.fetch("NRCD") == "99" && query.fetch("TIPO") == "E" }
    assert_equal "20260501", order_queries(http).first.fetch("DATADA")
    assert_equal "20260531", order_queries(http).first.fetch("DATAA")
    assert_equal 2, http.calls.count { |call| call.fetch(:operation) == :account_identity }
    assert_equal 2, http.calls.count { |call| call.fetch(:operation) == :startup_metadata }
    assert result.orders.frozen?
    assert result.orders.first.frozen?
    refute_includes result.inspect, session.multi_token
    refute_includes result.inspect, "00000000000001"
  end

  test "requests an empty sentinel after a full one hundred row page" do
    rows = (1..100).map do |number|
      order_row(number, format("%014d", number), event_date: 20260513)
    end
    responses = identity_responses + [
      response(:executed_orders, { "ORDER" => rows }),
      response(:executed_orders, { "ORDER" => [] })
    ] + identity_responses
    http = FakeHttpTransport.new(*responses)

    result = history(http).fetch_orders(date_from: "20260501", date_to: "20260531")

    assert_equal 100, result.orders.length
    assert_equal [ "0", "100" ], order_queries(http).map { |query| query.fetch("RCDDA") }
    assert result.complete
  end

  test "rejects out of bounds and malformed dates before making requests" do
    http = FakeHttpTransport.new
    client = history(http)
    current_bank_date = Time.current.in_time_zone("Europe/Rome").to_date

    [
      [ "20260501&TOKEN=other", "20260531" ],
      [ Date.new(2017, 12, 31), Date.new(2018, 1, 1) ],
      [ Date.new(2026, 5, 31), Date.new(2026, 5, 1) ],
      [ Date.new(2026, 5, 1), current_bank_date ]
    ].each do |from, to|
      assert_raises(Provider::Directa::ConfigurationError) do
        client.fetch_orders(date_from: from, date_to: to)
      end
    end

    assert_raises(Provider::Directa::ConfigurationError) do
      client.fetch_statement(date: "20260531&USER=other")
    end
    assert_empty http.calls
  end

  test "rejects row sequence gaps, duplicate references, and events outside the range" do
    invalid_pages = [
      { "ORDER" => [ order_row(2, "00000000000001", event_date: 20260503) ] },
      { "ORDER" => [ order_row(1, "00000000000001", event_date: 20260503), order_row(2, "00000000000001", event_date: 20260504) ] },
      { "ORDER" => [ order_row(1, "00000000000001", event_date: 20260601) ] }
    ]
    expected_codes = [ :history_sequence_invalid, :duplicate_history_reference, :history_date_out_of_range ]

    invalid_pages.zip(expected_codes).each do |payload, failure_code|
      http = FakeHttpTransport.new(*identity_responses, response(:executed_orders, payload))

      error = assert_raises(Provider::Directa::InvalidResponse) do
        history(http).fetch_orders(date_from: "20260501", date_to: "20260531")
      end

      assert_equal failure_code, error.failure_code
      assert_equal 1, http.calls.count { |call| call.fetch(:operation) == :executed_orders }
    end
  end

  test "rejects a history redirect without leaking its body or token" do
    redirect_body = "redirect to #{session.multi_token}"
    http = FakeHttpTransport.new(*identity_responses, response(:executed_orders, redirect_body, status: 302))

    error = assert_raises(Provider::Directa::RedirectRejected) do
      history(http).fetch_orders(date_from: "20260501", date_to: "20260531")
    end

    assert_equal :redirect_rejected, error.failure_code
    refute_includes error.message, session.multi_token
    refute_includes error.message, "redirect to"
  end

  test "fetches the bounded account statement as unchanged ISO-8859-1 bytes" do
    body = "date,value\n03/05/2026,\xE9".b
    http = FakeHttpTransport.new(*identity_responses, response(:account_statement, body), *identity_responses)

    result = history(http).fetch_statement(date: Date.new(2026, 5, 31))
    call = http.calls.find { |entry| entry.fetch(:operation) == :account_statement }

    assert_equal body.bytes, result.body.bytes
    assert_equal Encoding::BINARY, result.body.encoding
    assert_equal Encoding::ISO_8859_1, result.source_encoding
    assert_equal Date.new(2026, 5, 31), result.date
    assert_equal session.connection_generation, result.scope.connection_generation
    assert_equal({
      "USER" => session.mono_token,
      "TPGE" => "A00",
      "DATE" => "31052026",
      "TIPOUT" => "MAC"
    }, call.fetch(:query))
    refute_includes result.inspect, session.mono_token
    refute_includes result.inspect, "03/05/2026"
  end

  test "rechecks account identity after the complete order history read" do
    responses = identity_responses + [
      response(:executed_orders, { "ORDER" => [] })
    ] + identity_responses(trading_account: "99999", startup_account: "99999")
    http = FakeHttpTransport.new(*responses)

    error = assert_raises(Provider::Directa::AccountIdentityMismatch) do
      history(http).fetch_orders(date_from: "20260501", date_to: "20260531")
    end

    assert_equal :account_identity_changed, error.failure_code
  end

  test "stops without returning partial history when the page bound is reached" do
    rows = (1..50).map do |number|
      response(:executed_orders, { "ORDER" => [ order_row(number, format("%014d", number), event_date: 20260513) ] })
    end
    http = FakeHttpTransport.new(*identity_responses, *rows)

    error = assert_raises(Provider::Directa::ResponseTooLarge) do
      history(http).fetch_orders(date_from: "20260501", date_to: "20260531")
    end

    assert_equal :history_limit_exceeded, error.failure_code
    assert_equal 50, order_queries(http).length
    deadlines = http.calls.map { |call| call.fetch(:deadline) }.uniq
    assert_equal 1, deadlines.length
    assert_operator deadlines.first, :>, Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  test "maps the two history reads to fixed HTTPS GET paths" do
    routes = Provider::Directa::HttpTransport::ROUTES

    assert_equal [ :get, "/trading/zordj" ], routes.fetch(:executed_orders)
    assert_equal [ :get, "/trading/estconc8" ], routes.fetch(:account_statement)
  end

  private

    def history(http)
      Provider::Directa::History.new(session: session, http_transport: http)
    end

    def session
      @session ||= begin
        token = "abcdefgh12345678abcdefgh12345678"
        multi_token = "8#{token[1]}9#{token[3..]}"
        Provider::Directa::VerifiedSession.new(
          account_number: "00123",
          account_identity: "123",
          multi_token: multi_token,
          mono_token: "4#{multi_token[1..]}",
          host: Provider::Directa::HOST,
          connection_generation: 7
        )
      end
    end

    def identity_responses(trading_account: "123", startup_account: "123")
      [
        response(:account_identity, "#{trading_account}\r\n"),
        response(:startup_metadata, { "userInfo" => { "conto" => startup_account } }.to_json)
      ]
    end

    def response(operation, body, status: 200)
      body = body.to_json unless body.is_a?(String)
      FakeResponse.new(
        operation: operation,
        response: Provider::Directa::HttpTransport::Response.new(status: status, body: body)
      )
    end

    def order_row(row_number, reference, event_date:, entry_date: 20260503)
      {
        "Row" => row_number,
        "Riferimento" => reference,
        "DataEvento" => event_date,
        "DataImmissione" => entry_date,
        "AcqVen" => "C",
        "Stato" => "e "
      }
    end

    def order_queries(http)
      http.calls.filter_map do |call|
        call.fetch(:query) if call.fetch(:operation) == :executed_orders
      end
    end

    FakeResponse = Struct.new(:operation, :response, keyword_init: true)

    class FakeHttpTransport
      attr_reader :calls

      def initialize(*responses)
        @responses = responses
        @calls = []
      end

      def request(operation, **options)
        @calls << { operation: operation, query: duplicate(options[:query]), deadline: options[:deadline] }
        response = @responses.shift
        raise "unexpected Directa request" unless response&.operation == operation

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
end
