require "test_helper"

class Provider::Openai::BankStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @client = mock("openai_client")
    @model = "gpt-4.1"
  end

  test "extracts transactions from PDF content" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => {
              "start_date" => "2024-01-01",
              "end_date" => "2024-01-31"
            },
            "opening_balance" => 5000.00,
            "closing_balance" => 4500.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Coffee Shop", "amount" => -5.50 },
              { "date" => "2024-01-20", "description" => "Salary Deposit", "amount" => 3000.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    # Mock the PDF text extraction
    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 bank statement text" ])

    result = extractor.extract

    assert_equal "Test Bank", result[:bank_name]
    assert_equal "John Doe", result[:account_holder]
    assert_equal "1234", result[:account_number]
    assert_equal 5000.00, result[:opening_balance]
    assert_equal 4500.00, result[:closing_balance]
    assert_equal 2, result[:transactions].size

    first_txn = result[:transactions].first
    assert_equal "2024-01-15", first_txn[:date]
    assert_equal "Coffee Shop", first_txn[:name]
    assert_equal(-5.50, first_txn[:amount])
  end

  test "handles empty PDF content" do
    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "",
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "handles nil PDF content" do
    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: nil,
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "deduplicates transactions across chunk boundaries" do
    # First chunk response
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => { "start_date" => "2024-01-01", "end_date" => "2024-01-31" },
            "opening_balance" => 5000.00,
            "closing_balance" => 4500.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Coffee Shop", "amount" => -5.50 },
              { "date" => "2024-01-16", "description" => "Grocery Store", "amount" => -50.00 }
            ]
          }.to_json
        }
      } ]
    }

    # Second chunk response with duplicate at boundary
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => [
              { "date" => "2024-01-16", "description" => "Grocery Store", "amount" => -50.00 },
              { "date" => "2024-01-17", "description" => "Gas Station", "amount" => -40.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    # Mock multiple pages that will create multiple chunks
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,  # ~3500 chars, first chunk
      "Page 2 " * 500   # ~3500 chars, second chunk
    ])

    result = extractor.extract

    # Should deduplicate the "Grocery Store" transaction at chunk boundary
    assert_equal 3, result[:transactions].size
    names = result[:transactions].map { |t| t[:name] }
    assert_includes names, "Coffee Shop"
    assert_includes names, "Grocery Store"
    assert_includes names, "Gas Station"
  end

  test "normalizes transaction amounts" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Test 1", "amount" => "-$5.50" },
              { "date" => "2024-01-16", "description" => "Test 2", "amount" => "1,234.56" },
              { "date" => "2024-01-17", "description" => "Test 3", "amount" => -100 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal(-5.50, result[:transactions][0][:amount])
    assert_equal 1234.56, result[:transactions][1][:amount]
    assert_equal(-100.0, result[:transactions][2][:amount])
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

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    # Should return empty transactions on parse error
    assert_equal [], result[:transactions]
  end
end
