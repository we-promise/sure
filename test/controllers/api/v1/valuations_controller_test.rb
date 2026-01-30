# frozen_string_literal: true

require "test_helper"

class Api::V1::ValuationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first
    @valuation = @family.entries.valuations.first.entryable

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys instead of using fixtures to avoid parallel test conflicts (rate limiting in test)
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"  # Use different source to allow multiple keys
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  # CREATE action tests
  test "should create valuation with valid parameters" do
    valuation_params = {
      valuation: {
        account_id: @account.id,
        amount: 10000.00,
        date: Date.current,
        notes: "Quarterly statement"
      }
    }

    assert_difference("@family.entries.valuations.count", 1) do
      post api_v1_valuations_url,
           params: valuation_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal Date.current.to_s, response_data["date"]
    assert_equal @account.id, response_data["account"]["id"]
  end

  test "should reject create with read-only API key" do
    valuation_params = {
      valuation: {
        account_id: @account.id,
        amount: 10000.00,
        date: Date.current
      }
    }

    post api_v1_valuations_url,
         params: valuation_params,
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject create with invalid account_id" do
    valuation_params = {
      valuation: {
        account_id: 999999,
        amount: 10000.00,
        date: Date.current
      }
    }

    post api_v1_valuations_url,
         params: valuation_params,
         headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject create with invalid parameters" do
    valuation_params = {
      valuation: {
        # Missing required fields
        account_id: @account.id
      }
    }

    post api_v1_valuations_url,
         params: valuation_params,
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should reject create without API key" do
    post api_v1_valuations_url, params: { valuation: { account_id: @account.id } }
    assert_response :unauthorized
  end

  # UPDATE action tests
  test "should update valuation with valid parameters" do
    entry = @valuation.entry
    update_params = {
      valuation: {
        amount: 15000.00,
        date: Date.current
      }
    }

    put api_v1_valuation_url(entry),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal Date.current.to_s, response_data["date"]
  end

  test "should update valuation notes only" do
    entry = @valuation.entry
    update_params = {
      valuation: {
        notes: "Updated notes"
      }
    }

    put api_v1_valuation_url(entry),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal "Updated notes", response_data["notes"]
  end

  test "should reject update with read-only API key" do
    entry = @valuation.entry
    update_params = {
      valuation: {
        amount: 15000.00
      }
    }

    put api_v1_valuation_url(entry),
        params: update_params,
        headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject update for non-existent valuation" do
    put api_v1_valuation_url(999999),
        params: { valuation: { amount: 15000.00 } },
        headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject update without API key" do
    entry = @valuation.entry
    put api_v1_valuation_url(entry), params: { valuation: { amount: 15000.00 } }
    assert_response :unauthorized
  end

  # JSON structure tests
  test "valuation JSON should have expected structure" do
    # Create a new valuation to test the structure
    entry = @account.entries.create!(
      name: Valuation.build_reconciliation_name(@account.accountable_type),
      date: Date.current,
      amount: 10000,
      currency: @account.currency,
      entryable: Valuation.new(kind: :reconciliation)
    )

    get api_v1_valuation_url(entry), headers: api_headers(@api_key)
    assert_response :success

    valuation_data = JSON.parse(response.body)

    # Basic fields
    assert_equal entry.id, valuation_data["id"]
    assert valuation_data.key?("id")
    assert valuation_data.key?("date")
    assert valuation_data.key?("amount")
    assert valuation_data.key?("currency")
    assert valuation_data.key?("kind")
    assert valuation_data.key?("created_at")
    assert valuation_data.key?("updated_at")

    # Account information
    assert valuation_data.key?("account")
    assert valuation_data["account"].key?("id")
    assert valuation_data["account"].key?("name")
    assert valuation_data["account"].key?("account_type")

    # Optional fields should be present (even if nil)
    assert valuation_data.key?("notes")
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
