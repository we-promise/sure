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
              { "date" => "2024-01-20", "action" => "buy", "ticker" => "GOOGL", "quantity" => 5, "price" => 140.00 }
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
              { "date" => "2024-01-20", "action" => "buy", "ticker" => "GOOGL", "quantity" => 5, "price" => 140.00 },
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

    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500
    ])

    result = extractor.extract

    assert_equal 3, result[:trades].size
    tickers = result[:trades].map { |t| t[:ticker] }
    assert_includes tickers, "AAPL"
    assert_includes tickers, "GOOGL"
    assert_includes tickers, "TSLA"
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
