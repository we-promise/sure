# frozen_string_literal: true

require "test_helper"

class Provider::IndexaCapitalTest < ActiveSupport::TestCase
  test "initializes with api_token" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")
    assert_instance_of Provider::IndexaCapital, provider
  end

  test "initializes with username/document/password" do
    provider = Provider::IndexaCapital.new(
      username: "user@example.com",
      document: "12345678A",
      password: "secret"
    )
    assert_instance_of Provider::IndexaCapital, provider
  end

  test "raises ConfigurationError without credentials" do
    assert_raises Provider::IndexaCapital::ConfigurationError do
      Provider::IndexaCapital.new
    end
  end

  test "raises ConfigurationError with partial credentials" do
    assert_raises Provider::IndexaCapital::ConfigurationError do
      Provider::IndexaCapital.new(username: "user@example.com")
    end

    assert_raises Provider::IndexaCapital::ConfigurationError do
      Provider::IndexaCapital.new(username: "user@example.com", document: "12345678A")
    end
  end

  test "list_accounts calls API and returns accounts" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    stub_response = OpenStruct.new(
      code: 200,
      body: {
        accounts: [
          { account_number: "ABC12345", type: "mutual", status: "active" },
          { account_number: "DEF67890", type: "pension", status: "active" }
        ]
      }.to_json
    )

    Provider::IndexaCapital.stubs(:get).returns(stub_response)

    accounts = provider.list_accounts
    assert_equal 2, accounts.size
    assert_equal "ABC12345", accounts[0][:account_number]
    assert_equal "Indexa Capital Mutual Fund (ABC12345)", accounts[0][:name]
    assert_equal "EUR", accounts[0][:currency]
    assert_equal "DEF67890", accounts[1][:account_number]
    assert_equal "Indexa Capital Pension Plan (DEF67890)", accounts[1][:name]
  end

  test "get_holdings calls fiscal-results endpoint" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    stub_response = OpenStruct.new(
      code: 200,
      body: {
        fiscal_results: [
          { amount: 1814.77, titles: 9.14, price: 175.34, instrument: { identifier: "IE00BFPM9P35" } }
        ],
        total_fiscal_results: []
      }.to_json
    )

    Provider::IndexaCapital.stubs(:get).returns(stub_response)

    data = provider.get_holdings(account_number: "ABC12345")
    assert data[:fiscal_results].is_a?(Array)
    assert_equal 1, data[:fiscal_results].size
  end

  test "get_account_balance extracts total_amount from portfolios" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    stub_response = OpenStruct.new(
      code: 200,
      body: {
        portfolios: [
          { date: "2026-02-05", total_amount: 38000.0 },
          { date: "2026-02-06", total_amount: 38905.21 }
        ]
      }.to_json
    )

    Provider::IndexaCapital.stubs(:get).returns(stub_response)

    balance = provider.get_account_balance(account_number: "ABC12345")
    assert_equal 38905.21.to_d, balance
  end

  test "get_account_balance returns 0 when no portfolios" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    stub_response = OpenStruct.new(
      code: 200,
      body: { portfolios: [] }.to_json
    )

    Provider::IndexaCapital.stubs(:get).returns(stub_response)

    balance = provider.get_account_balance(account_number: "ABC12345")
    assert_equal 0, balance
  end

  test "get_activities returns empty array" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")
    result = provider.get_activities(account_number: "ABC12345")
    assert_equal [], result
  end

  test "raises AuthenticationError on 401" do
    provider = Provider::IndexaCapital.new(api_token: "bad_token")

    stub_response = OpenStruct.new(code: 401, body: "Unauthorized")
    Provider::IndexaCapital.stubs(:get).returns(stub_response)

    assert_raises Provider::IndexaCapital::AuthenticationError do
      provider.list_accounts
    end
  end

  test "rejects invalid account_number with path traversal" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    assert_raises Provider::IndexaCapital::Error do
      provider.get_holdings(account_number: "../admin")
    end
  end

  test "rejects blank account_number" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    assert_raises Provider::IndexaCapital::Error do
      provider.get_holdings(account_number: "")
    end
  end

  test "raises Error on server error" do
    provider = Provider::IndexaCapital.new(api_token: "test_token")

    stub_response = OpenStruct.new(code: 500, body: "Internal Server Error")
    Provider::IndexaCapital.stubs(:get).returns(stub_response)

    assert_raises Provider::IndexaCapital::Error do
      provider.list_accounts
    end
  end
end
