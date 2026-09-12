require "test_helper"
require_relative "../../../../support/financekit_test_helper"

class Api::V1::Financekit::ConnectionsControllerTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper
  include ActiveJob::TestHelper
  setup do
    financekit_setup
    @user.api_keys.active.destroy_all
    @key = ApiKey.create!(user: @user, name: "FinanceKit test", scopes: [ "read_write" ],
      display_key: "test_#{SecureRandom.hex(16)}", source: "web")
    @headers = { "X-Api-Key" => @key.display_key }
    ApiRateLimiter.stubs(:limit).returns(nil)
  end

  test "capabilities and enrollment are authenticated and scoped" do
    get "/api/v1/financekit/capabilities"
    assert_response :unauthorized
    get "/api/v1/financekit/capabilities", headers: @headers
    assert_response :success
    assert_equal true, response.parsed_body["available"]
    assert_equal "foreground_sync", response.parsed_body["delivery"]
    post "/api/v1/financekit/connections", params: @enrollment, headers: @headers, as: :json
    assert_response :created
    assert_equal @item.id, response.parsed_body["id"]
    @key.update!(scopes: [ "read" ])
    post "/api/v1/financekit/connections", params: @enrollment, headers: @headers, as: :json
    assert_response :forbidden
  end

  test "disabled capability is explicit and existing read only API remains available" do
    Financekit.stubs(:enabled?).returns(false)
    get "/api/v1/financekit/capabilities", headers: @headers
    assert_response :success
    assert_equal false, response.parsed_body["available"]
    get "/api/v1/accounts", headers: @headers
    assert_response :success
    post "/api/v1/financekit/connections", params: @enrollment, headers: @headers, as: :json
    assert_response :service_unavailable
    assert_equal "60", response.headers["Retry-After"]
  end

  test "connection mappings paginate and do not expose source payloads" do
    get "/api/v1/financekit/connections/#{@item.id}", headers: @headers, params: { page: 2, per_page: 1 }
    assert_response :success
    assert_empty response.parsed_body["accounts"]
    assert_equal 1, response.parsed_body["pagination"]["total_count"]
    assert_not_includes response.body, "raw_payload"
    get "/api/v1/financekit/connections/#{SecureRandom.uuid}", headers: @headers
    assert_response :not_found
  end

  test "mapping replay is explicit and mismatched optimistic version conflicts" do
    put "/api/v1/financekit/connections/#{@item.id}/account_mappings/#{@source_id}", params: @mapping_input, headers: @headers, as: :json
    assert_response :success
    put "/api/v1/financekit/connections/#{@item.id}/account_mappings/#{@source_id}", params: @mapping_input.merge("expected_version" => 9), headers: @headers, as: :json
    assert_response :conflict
  end

  test "foreground sync imports immediately and normal Sure APIs see the result" do
    @family.rules.update_all(active: false)
    category = @family.categories.create!(name: "Wallet test purchases")
    @family.rules.create!(resource_type: "transaction", active: true, effective_date: Date.new(2026, 1, 1),
      conditions: [ Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: "0") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ])
    perform_enqueued_jobs(only: RuleJob) do
      post "/api/v1/financekit/connections/#{@item.id}/syncs", params: financekit_payload, headers: @headers, as: :json
    end
    assert_response :created
    assert_equal "applied", response.parsed_body["status"]
    assert_equal 1, response.parsed_body.dig("counts", "upserted")
    assert_equal category, @source.account.entries.sole.transaction.category
    assert_equal BigDecimal("112.66"), @source.account.reload.balance
    get "/api/v1/transactions", headers: @headers
    assert_response :success
    assert_includes response.body, "Synthetic shop"
    post "/api/v1/financekit/connections/#{@item.id}/syncs", params: financekit_payload, headers: @headers, as: :json
    assert_response :created
    assert_equal 1, @source.account.entries.count
  end

  test "disconnect rejects future syncs" do
    delete "/api/v1/financekit/connections/#{@item.id}", headers: @headers
    assert_response :no_content
    assert_equal "revoked", @item.reload.status
    post "/api/v1/financekit/connections/#{@item.id}/syncs", params: financekit_payload, headers: @headers, as: :json
    assert_response :forbidden
  end

  test "foreign family and invalid money cannot be mapped" do
    @item.update!(user: users(:family_member))
    get "/api/v1/financekit/connections/#{@item.id}", headers: @headers
    assert_response :not_found
    @item.update!(user: @user)
    put "/api/v1/financekit/connections/#{@item.id}/account_mappings/#{@source_id}", headers: @headers, as: :json,
      params: @mapping_input.merge("currency" => "INVALID")
    assert_response :unprocessable_entity
  end

  test "read only credentials cannot map sync or disconnect" do
    @key.update!(scopes: [ "read" ])
    put "/api/v1/financekit/connections/#{@item.id}/account_mappings/#{@source_id}",
      params: @mapping_input, headers: @headers, as: :json
    assert_response :forbidden
    post "/api/v1/financekit/connections/#{@item.id}/syncs", params: financekit_payload, headers: @headers, as: :json
    assert_response :forbidden
    delete "/api/v1/financekit/connections/#{@item.id}", headers: @headers
    assert_response :forbidden
    assert_equal "active", @item.reload.status
  end
end
