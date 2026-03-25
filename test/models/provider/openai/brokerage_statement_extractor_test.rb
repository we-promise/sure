require "test_helper"

class Provider::Openai::BrokerageStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @client = mock("openai_client")
    @model = "gpt-4.1"
  end

  test "extracts trades from PDF content" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "broker_name" => "Interactive Brokers",
            "account_holder" => "Jane Doe",
            "account_number" => "5678",
            "statement_period" => {
              "start_date" => "2024-01-01",
              "end_date" => "2024-03-31"
            },
            "currency" => "USD",
            "trades" => [
              { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "security" => "Apple Inc.", "quantity" => 10, "price" => 175.50, "fees" => 1.00 },
              { "date" => "2024-02-20", "action" => "sell", "ticker" => "MSFT", "security" => "Microsoft Corp.", "quantity" => 5, "price" => 380.00, "fees" => 0.50 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 brokerage statement" ])

    result = extractor.extract

    assert_equal "Interactive Brokers", result[:broker_name]
    assert_equal "Jane Doe", result[:account_holder]
    assert_equal "5678", result[:account_number]
    assert_equal "USD", result[:currency]
    assert_equal 2, result[:trades].size

    buy_trade = result[:trades].first
    assert_equal "2024-01-15", buy_trade[:date]
    assert_equal "AAPL", buy_trade[:ticker]
    assert_equal 10.0, buy_trade[:qty]
    assert_equal 175.50, buy_trade[:price]
    assert_equal "Apple Inc.", buy_trade[:name]

    sell_trade = result[:trades].last
    assert_equal "2024-02-20", sell_trade[:date]
    assert_equal "MSFT", sell_trade[:ticker]
    assert_equal(-5.0, sell_trade[:qty])
    assert_equal 380.00, sell_trade[:price]
  end

  test "handles empty PDF content" do
    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "",
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "handles nil PDF content" do
    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: nil,
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "splits a single oversized page into multiple chunks under MAX_CHARS_PER_CHUNK" do
    max = Provider::Openai::BrokerageStatementExtractor::MAX_CHARS_PER_CHUNK
    huge_page = "x" * (max * 3)

    trade_payload = {
      "trades" => [
        { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 1, "price" => 100.00 }
      ]
    }
    empty_payload = { "trades" => [] }

    responses = [
      { "choices" => [ { "message" => { "content" => trade_payload.to_json } } ] },
      { "choices" => [ { "message" => { "content" => empty_payload.to_json } } ] },
      { "choices" => [ { "message" => { "content" => empty_payload.to_json } } ] }
    ]

    @client.expects(:chat).times(3).returns(*responses)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ huge_page ])

    result = extractor.extract

    assert_equal 1, result[:trades].size
    assert_equal "AAPL", result[:trades].first[:ticker]
  end

  test "deduplicates trades across chunk boundaries" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "broker_name" => "Fidelity",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => { "start_date" => "2024-01-01", "end_date" => "2024-03-31" },
            "currency" => "USD",
            "trades" => [
              { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 10, "price" => 175.50 },
              { "date" => "2024-01-20", "action" => "buy", "ticker" => "GOOGL", "quantity" => 5, "price" => 140.00, "order_id" => "GOOGL-1" }
            ]
          }.to_json
        }
      } ]
    }

    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "trades" => [
              { "date" => "2024-01-20", "action" => "buy", "ticker" => "GOOGL", "quantity" => 5, "price" => 140.00, "order_id" => "GOOGL-1" },
              { "date" => "2024-02-10", "action" => "sell", "ticker" => "TSLA", "quantity" => 3, "price" => 200.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    max = Provider::Openai::BrokerageStatementExtractor::MAX_CHARS_PER_CHUNK
    pad = "x" * (max - 500)
    extractor.stubs(:extract_pages_from_pdf).returns([ "P1#{pad}", "P2#{pad}" ])

    result = extractor.extract

    assert_equal 3, result[:trades].size
    tickers = result[:trades].map { |t| t[:ticker] }
    assert_includes tickers, "AAPL"
    assert_includes tickers, "GOOGL"
    assert_includes tickers, "TSLA"
  end

  test "keeps weak-identical trades in neighboring chunks when no order id or time" do
    row = { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 10, "price" => 175.50 }
    first_response = {
      "choices" => [ { "message" => { "content" => { "trades" => [ row ] }.to_json } } ]
    }
    second_response = {
      "choices" => [ { "message" => { "content" => { "trades" => [ row ] }.to_json } } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    max = Provider::Openai::BrokerageStatementExtractor::MAX_CHARS_PER_CHUNK
    pad = "x" * (max - 500)
    extractor.stubs(:extract_pages_from_pdf).returns([ "P1#{pad}", "P2#{pad}" ])

    result = extractor.extract

    assert_equal 2, result[:trades].size
    assert_equal [ "AAPL", "AAPL" ], result[:trades].map { |t| t[:ticker] }
  end

  test "deduplicates duplicate weak rows within the same chunk" do
    row = { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 10, "price" => 175.50 }
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => { "trades" => [ row, row ] }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "short page" ])

    result = extractor.extract

    assert_equal 1, result[:trades].size
  end

  test "merges summary metadata from later chunks when omitted on first chunk" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "broker_name" => "Sample Broker",
            "statement_period" => { "start_date" => "2024-01-01", "end_date" => "2024-01-31" },
            "trades" => [
              { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 1, "price" => 100.00 }
            ]
          }.to_json
        }
      } ]
    }

    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "cash_balance" => 500.0,
            "total_value" => 10_000.0,
            "as_of_date" => "2024-03-31",
            "statement_period" => { "end_date" => "2024-03-31" },
            "trades" => [
              { "date" => "2024-02-01", "action" => "buy", "ticker" => "MSFT", "quantity" => 2, "price" => 200.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    max = Provider::Openai::BrokerageStatementExtractor::MAX_CHARS_PER_CHUNK
    pad = "x" * (max - 500)
    extractor.stubs(:extract_pages_from_pdf).returns([ "P1#{pad}", "P2#{pad}" ])

    result = extractor.extract

    assert_equal "Sample Broker", result[:broker_name]
    assert_equal 500.0, result[:cash_balance]
    assert_equal 10_000.0, result[:total_value]
    assert_equal "2024-03-31", result[:as_of_date]
    assert_equal "2024-01-01", result[:period][:start_date]
    assert_equal "2024-03-31", result[:period][:end_date]
  end

  test "identity metadata from first chunk wins when repeated in later chunk" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "broker_name" => "First Broker",
            "currency" => "USD",
            "trades" => [
              { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 1, "price" => 100.00 }
            ]
          }.to_json
        }
      } ]
    }

    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "broker_name" => "Other Broker",
            "currency" => "EUR",
            "trades" => [
              { "date" => "2024-02-01", "action" => "buy", "ticker" => "MSFT", "quantity" => 2, "price" => 200.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    max = Provider::Openai::BrokerageStatementExtractor::MAX_CHARS_PER_CHUNK
    pad = "x" * (max - 500)
    extractor.stubs(:extract_pages_from_pdf).returns([ "P1#{pad}", "P2#{pad}" ])

    result = extractor.extract

    assert_equal "First Broker", result[:broker_name]
    assert_equal "USD", result[:currency]
  end

  test "normalizes sell actions to negative quantity" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "trades" => [
              { "date" => "2024-01-15", "action" => "sell", "ticker" => "AAPL", "quantity" => 10, "price" => 175.50 },
              { "date" => "2024-01-16", "action" => "sold", "ticker" => "MSFT", "quantity" => 5, "price" => 380.00 },
              { "date" => "2024-01-17", "action" => "buy", "ticker" => "GOOGL", "quantity" => 20, "price" => 140.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal(-10.0, result[:trades][0][:qty])
    assert_equal(-5.0, result[:trades][1][:qty])
    assert_equal 20.0, result[:trades][2][:qty]
  end

  test "skips trades missing ticker" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "trades" => [
              { "date" => "2024-01-15", "action" => "buy", "ticker" => "AAPL", "quantity" => 10, "price" => 175.50 },
              { "date" => "2024-01-16", "action" => "buy", "ticker" => "", "quantity" => 5, "price" => 100.00 },
              { "date" => "2024-01-17", "action" => "buy", "quantity" => 5, "price" => 100.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal 1, result[:trades].size
    assert_equal "AAPL", result[:trades].first[:ticker]
  end

  test "parse_amount parses US and European string formats" do
    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    assert_in_delta 1234.56, extractor.send(:parse_amount, "1,234.56"), 0.001
    assert_in_delta 1234.56, extractor.send(:parse_amount, "1.234,56"), 0.001
    assert_in_delta 1234.56, extractor.send(:parse_amount, "1234,56"), 0.001
    assert_in_delta(-99.99, extractor.send(:parse_amount, "-99,99"), 0.001)
    assert_equal 175.5, extractor.send(:parse_amount, 175.5)
    assert_nil extractor.send(:parse_amount, nil)
  end

  test "normalizes trades with European-formatted price strings" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "trades" => [
              { "date" => "2024-01-15", "action" => "buy", "ticker" => "VWCE", "quantity" => 10, "price" => "1.234,56", "fees" => "12,50" }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    trade = result[:trades].first
    assert_in_delta 1234.56, trade[:price], 0.001
    assert_in_delta 12.50, trade[:fees], 0.001
  end

  test "handles malformed JSON response gracefully" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => "This is not valid JSON"
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BrokerageStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal [], result[:trades]
  end
end
