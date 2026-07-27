require "test_helper"

class Provider::PlaidTest < ActiveSupport::TestCase
  setup do
    # Do not change, this is whitelisted in the Plaid Dashboard for local dev
    @redirect_url = "http://localhost:3000/accounts"

    with_env_overrides(
      "PLAID_CLIENT_ID" => "foo",
      "PLAID_SECRET" => "bar"
    ) do
      Provider::PlaidAdapter.reload_configuration
    end

    # A specialization of Plaid client with sandbox-only extensions
    @plaid = Provider::PlaidSandbox.new
  end

  teardown do
    Provider::PlaidAdapter.reload_configuration
  end

  test "gets link token" do
    VCR.use_cassette("plaid/link_token") do
      link_token = @plaid.get_link_token(
        user_id: "test-user-id",
        webhooks_url: "https://example.com/webhooks",
        redirect_url: @redirect_url
      )

      assert_match /link-sandbox-.*/, link_token.link_token
    end
  end

  test "exchanges public token" do
    VCR.use_cassette("plaid/exchange_public_token") do
      public_token = @plaid.create_public_token
      exchange_response = @plaid.exchange_public_token(public_token)

      assert_match /access-sandbox-.*/, exchange_response.access_token
    end
  end

  test "gets item" do
    VCR.use_cassette("plaid/get_item") do
      access_token = get_access_token
      item = @plaid.get_item(access_token).item

      assert_equal "ins_109508", item.institution_id
      assert_equal "First Platypus Bank", item.institution_name
    end
  end

  test "gets item accounts" do
    VCR.use_cassette("plaid/get_item_accounts") do
      access_token = get_access_token
      accounts_response = @plaid.get_item_accounts(access_token)

      assert_equal 4, accounts_response.accounts.size
    end
  end

  test "gets item investments" do
    VCR.use_cassette("plaid/get_item_investments") do
      access_token = get_access_token
      investments_response = @plaid.get_item_investments(access_token)

      assert_equal 3, investments_response.holdings.size
      assert_equal 4, investments_response.transactions.size
    end
  end

  test "gets item liabilities" do
    VCR.use_cassette("plaid/get_item_liabilities") do
      access_token = get_access_token
      liabilities_response = @plaid.get_item_liabilities(access_token)

      assert liabilities_response.credit.count > 0
      assert liabilities_response.student.count > 0
    end
  end

  test "get_item_investment_transactions requests page size 500 and paces pages" do
    page1 = OpenStruct.new(
      investment_transactions: [ Object.new ],
      securities: [],
      total_investment_transactions: 2
    )
    page2 = OpenStruct.new(
      investment_transactions: [ Object.new ],
      securities: [],
      total_investment_transactions: 2
    )

    seen_counts = []
    @plaid.client.expects(:investments_transactions_get).twice.with do |request|
      opts = request.options
      seen_counts << (opts.is_a?(Hash) ? opts[:count] || opts["count"] : opts.try(:count))
      true
    end.returns(page1).then.returns(page2)

    @plaid.expects(:sleep).with(Provider::Plaid::INVESTMENTS_PAGE_INTERVAL_SECONDS).once

    transactions, _securities = @plaid.send(
      :get_item_investment_transactions,
      access_token: "access-token",
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 1, 31)
    )

    assert_equal 2, transactions.size
    assert_equal [ 500, 500 ], seen_counts
  end

  test "get_item_investments returns holdings when investment transactions are rate-limited" do
    holding = Object.new
    security = OpenStruct.new(security_id: "sec-1")

    @plaid.stubs(:get_item_holdings).returns([ [ holding ], [ security ] ])
    @plaid.stubs(:sleep)

    rate_limit_error = Plaid::ApiError.new(
      code: 429,
      response_headers: {},
      response_body: { error_code: "INVESTMENTS_LIMIT", error_message: "rate limited" }.to_json
    )
    @plaid.client.stubs(:investments_transactions_get).raises(rate_limit_error)

    DebugLogEntry.stubs(:capture)

    response = @plaid.get_item_investments("access-token", start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 1, 31))

    assert_equal [ holding ], response.holdings
    assert_equal [], response.transactions
    assert_equal [ security ], response.securities
  end

  private
    def get_access_token
      VCR.use_cassette("plaid/access_token") do
        public_token = @plaid.create_public_token
        exchange_response = @plaid.exchange_public_token(public_token)
        exchange_response.access_token
      end
    end
end
