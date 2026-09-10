require "test_helper"
require_relative "../../../../support/financekit_test_helper"

class Api::V1::Financekit::ConnectionsControllerTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper
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

  test "connection mappings paginate and do not expose device keys or upload data" do
    get "/api/v1/financekit/connections/#{@item.id}", headers: @headers, params: { page: 2, per_page: 1 }
    assert_response :success
    assert_empty response.parsed_body["accounts"]
    assert_equal 1, response.parsed_body["pagination"]["total_count"]
    assert_not_includes response.body, "device_public_key"
    assert_not_includes response.body, "envelope"
    get "/api/v1/financekit/connections/#{SecureRandom.uuid}", headers: @headers
    assert_response :not_found
  end

  test "mapping replay is explicit and mismatched optimistic version conflicts" do
    put "/api/v1/financekit/connections/#{@item.id}/account_mappings/#{@source_id}", params: @mapping_input, headers: @headers, as: :json
    assert_response :success
    put "/api/v1/financekit/connections/#{@item.id}/account_mappings/#{@source_id}", params: @mapping_input.merge("expected_version" => 9), headers: @headers, as: :json
    assert_response :conflict
  end

  test "general financial credentials do not authenticate the device endpoint" do
    post "/api/v1/financekit/connections/#{@item.id}/batches", params: "not-a-signature", headers: @headers.merge("CONTENT_TYPE" => "application/jose")
    assert_response :unauthorized
  end

  test "synthetic device can stop immediately after upload and read normal Sure data later" do
    envelope = financekit_envelope
    upload_url = "/api/v1/financekit/connections/#{@item.id}/batches"
    post upload_url, params: envelope, headers: { "CONTENT_TYPE" => "application/jose" }
    assert_response :accepted
    batch = @item.financekit_batches.sole
    Financekit::Downstream.any_instance.stubs(:perform!)
    FinancekitInboxJob.perform_now
    get "/api/v1/transactions", headers: @headers
    assert_response :success
    assert_includes response.body, "Synthetic shop"
    get "#{upload_url}/#{batch.batch_id}", params: { generation: 1 }, headers: @headers
    assert_response :success
    receipt, = JWT.decode(response.parsed_body["receipt"], @receipt_key, true, algorithms: [ "ES256" ])
    assert_equal "applied", receipt["status"]
    post upload_url, params: envelope, headers: { "CONTENT_TYPE" => "application/jose" }
    assert_response :accepted
    assert_equal 1, @source.account.entries.count
  end

  test "replacement and disconnect fence background imports" do
    post "/api/v1/financekit/connections/#{@item.id}/device_replacement", headers: @headers, as: :json,
      params: { expected_generation: 1, device_public_key: @device_jwk, consent: @enrollment["consent"], continuity: "same_source_and_transaction_ids" }
    assert_response :success
    assert_equal 2, response.parsed_body["generation"]
    delete "/api/v1/financekit/connections/#{@item.id}", headers: @headers
    assert_response :no_content
    assert_equal "revoked", @item.reload.status
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
end
