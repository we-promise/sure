require "test_helper"

class Provider::Plaid::IngestionClientTest < ActiveSupport::TestCase
  setup do
    @sdk = mock("Plaid authenticated SDK transport")
    @sdk.stubs(:config).returns(OpenStruct.new(debugging: false))
    @reader = Provider::Plaid::IngestionClient.new(api_client: @sdk, access_token: "private-item-token", region: "us")
  end

  test "SDK returns raw JSON before numeric model conversion and preserves auth names" do
    @sdk.expects(:call_api).with do |method, path, options|
      assert_equal :POST, method
      assert_equal "/accounts/get", path
      assert_equal "String", options[:return_type]
      assert_equal %w[clientId plaidVersion secret], options[:auth_names]
      assert_equal({ "access_token" => "private-item-token" }, JSON.parse(options[:body]))
      true
    end.returns([ '{"accounts":[{"balances":{"current":1.234567890123456789}}]}', 200, {} ])
    value = @reader.get_accounts
    assert_equal BigDecimal("1.234567890123456789"), value[:accounts].first[:balances][:current]
    refute_includes @reader.inspect, "private-item-token"
  end

  test "transaction reads consume a single bounded item-wide cursor page" do
    @sdk.expects(:call_api).with do |_, path, options|
      assert_equal "/transactions/sync", path
      body = JSON.parse(options[:body])
      assert_equal "cursor-0", body["cursor"]
      assert_equal 500, body["count"]
      assert_equal({ "include_original_description" => true }, body["options"])
      refute body["options"].key?("account_id")
      true
    end.returns([ transaction_page.to_json, 200, {} ])
    assert_equal "cursor-1", @reader.get_transactions_page(cursor: "cursor-0")[:next_cursor]
  end

  test "missing nonboolean and stalled transaction continuation fields are invalid" do
    [ transaction_page.except(:removed), transaction_page.merge(has_more: nil),
      transaction_page.merge(has_more: true, next_cursor: "cursor-0") ].each do |body|
      @sdk.expects(:call_api).returns([ body.to_json, 200, {} ])
      error = assert_raises(Provider::Plaid::IngestionClient::Error) { @reader.get_transactions_page(cursor: "cursor-0") }
      assert_equal "INVALID_RESPONSE", error.error_code
    end
  end

  test "fast-forward and oversized cursors are never sent during native migration" do
    @sdk.expects(:call_api).never
    [ "now", "x" * 257 ].each do |cursor|
      assert_raises(Provider::Plaid::IngestionClient::Error) { @reader.get_transactions_page(cursor: cursor) }
    end
  end

  test "mutations and login errors expose only stable codes and no SDK body or cause" do
    %w[TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION ITEM_LOGIN_REQUIRED].each do |code|
      error = ::Plaid::ApiError.new(code: 400, response_body: { error_code: code, error_message: "private-bank-description" }.to_json)
      @sdk.expects(:call_api).raises(error)
      raised = assert_raises(Provider::Plaid::IngestionClient::Error) { @reader.get_transactions_page }
      assert_equal code, raised.error_code
      refute_includes raised.message, "private-bank-description"
      assert_nil raised.cause
    end
  end

  test "regional institutions omit the item token and use region-specific country consent" do
    reader = Provider::Plaid::IngestionClient.new(api_client: @sdk, access_token: "private-item-token", region: "eu")
    @sdk.expects(:call_api).with do |_, path, options|
      assert_equal "/institutions/get_by_id", path
      body = JSON.parse(options[:body])
      refute body.key?("access_token")
      assert_includes body["country_codes"], "ES"
      refute_includes body["country_codes"], "US"
      true
    end.returns([ '{"institution":{"institution_id":"ins_1"}}', 200, {} ])
    assert_equal "ins_1", reader.get_institution(institution_id: "ins_1")[:institution][:institution_id]
  end

  test "investment page requests pin dates account offset and count without an internal pagination loop" do
    @sdk.expects(:call_api).with do |_, path, options|
      assert_equal "/investments/transactions/get", path
      body = JSON.parse(options[:body])
      assert_equal "2026-01-01", body["start_date"]
      assert_equal "2026-09-14", body["end_date"]
      assert_equal({ "account_ids" => [ "a" ], "offset" => 0, "count" => 500 }, body["options"])
      true
    end.returns([ { investment_transactions: [ {} ], total_investment_transactions: 2, accounts: [], securities: [] }.to_json, 200, {} ])
    assert_equal 2, @reader.get_investment_transactions_page(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 9, 14), account_id: "a")[:total_investment_transactions]
  end

  test "empty pages before the advertised investment total cannot complete successfully" do
    @sdk.expects(:call_api).returns([ { investment_transactions: [], total_investment_transactions: 1, accounts: [], securities: [] }.to_json, 200, {} ])
    assert_raises(Provider::Plaid::IngestionClient::Error) do
      @reader.get_investment_transactions_page(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 9, 14))
    end
  end

  test "liabilities permit explicitly unavailable types without accepting malformed arrays" do
    @sdk.expects(:call_api).returns([ '{"liabilities":{"credit":null,"mortgage":[],"student":null}}', 200, {} ])
    assert_nil @reader.get_liabilities[:liabilities][:credit]
    @sdk.expects(:call_api).returns([ '{"liabilities":{"credit":{}}}', 200, {} ])
    assert_raises(Provider::Plaid::IngestionClient::Error) { @reader.get_liabilities }
  end

  test "a debug-enabled SDK cannot log credentials through the native reader" do
    @sdk.stubs(:config).returns(OpenStruct.new(debugging: true))
    assert_raises(ArgumentError) { Provider::Plaid::IngestionClient.new(api_client: @sdk, access_token: "private", region: "us") }
  end

  test "a successful item HTTP response with a login error cannot claim a healthy grant" do
    @sdk.expects(:call_api).returns([ { item: { item_id: "item-1", error: { error_code: "ITEM_LOGIN_REQUIRED", error_message: "private" } } }.to_json, 200, {} ])
    error = assert_raises(Provider::Plaid::IngestionClient::Error) { @reader.get_item }
    assert_equal "ITEM_LOGIN_REQUIRED", error.error_code
    refute_includes error.message, "private"
  end

  private
    def transaction_page
      { added: [], modified: [], removed: [], has_more: false, next_cursor: "cursor-1" }
    end
end
