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
      source: "web",
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

  # INDEX action tests
  test "should get index with valid API key" do
    get api_v1_valuations_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("valuations")
    assert response_data.key?("pagination")
    assert response_data["valuations"].is_a?(Array)
    assert response_data["pagination"].key?("page")
    assert response_data["pagination"].key?("per_page")
    assert response_data["pagination"].key?("total_count")
    assert response_data["pagination"].key?("total_pages")
  end

  test "should get index with read-only API key" do
    get api_v1_valuations_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should filter index by account_id" do
    get api_v1_valuations_url,
        params: { account_id: @account.id },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    response_data["valuations"].each do |valuation|
      assert_equal @account.id, valuation["account"]["id"]
    end
  end

  test "should filter index by date range" do
    entry = @valuation.entry

    get api_v1_valuations_url,
        params: { start_date: entry.date, end_date: entry.date },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_includes response_data["valuations"].map { |valuation| valuation["id"] }, entry.id
    response_data["valuations"].each do |valuation|
      valuation_date = Date.iso8601(valuation["date"])
      assert_equal entry.date, valuation_date
    end
  end

  test "should reject index with invalid date filter" do
    get api_v1_valuations_url,
        params: { start_date: "04/30/2026" },
        headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should reject index with malformed account_id filter" do
    get api_v1_valuations_url,
        params: { account_id: "not-a-uuid" },
        headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "account_id must be a valid UUID", response_data["message"]
  end

  test "should not expose internal index errors" do
    Api::V1::ValuationsController.any_instance.stubs(:safe_page_param).raises(StandardError, "database password leaked")

    get api_v1_valuations_url, headers: api_headers(@api_key)
    assert_response :internal_server_error

    response_data = JSON.parse(response.body)
    assert_equal "internal_server_error", response_data["error"]
    assert_equal "An unexpected error occurred", response_data["message"]
    assert_not_includes response.body, "database password leaked"
  end

  test "should reject index without API key" do
    get api_v1_valuations_url
    assert_response :unauthorized
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

  test "should upsert valuation for same account and date when requested" do
    existing_entry = @valuation.entry
    valuation_params = {
      upsert: "true",
      valuation: {
        account_id: existing_entry.account.id,
        amount: 12_345.67,
        date: existing_entry.date,
        notes: "API correction"
      }
    }

    assert_no_difference("@family.entries.valuations.count") do
      post api_v1_valuations_url,
           params: valuation_params,
           headers: api_headers(@api_key)
    end

    assert_response :ok
    response_data = JSON.parse(response.body)
    assert_equal existing_entry.id, response_data["id"]
    assert_equal existing_entry.date.to_s, response_data["date"]
    assert_equal "API correction", response_data["notes"]
    assert_equal BigDecimal("12345.67"), existing_entry.reload.amount
  end

  test "should create valuation when upsert is requested without an existing same-date valuation" do
    valuation_date = Date.current + 3.days
    valuation_params = {
      upsert: "true",
      valuation: {
        account_id: @account.id,
        amount: 9876.54,
        date: valuation_date,
        notes: "New API valuation"
      }
    }

    assert_difference("@family.entries.valuations.count", 1) do
      post api_v1_valuations_url,
           params: valuation_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal valuation_date.to_s, response_data["date"]
    assert_equal "New API valuation", response_data["notes"]
  end

  test "should accept nested upsert flag for same-date valuation writes" do
    existing_entry = @valuation.entry
    valuation_params = {
      valuation: {
        account_id: existing_entry.account.id,
        amount: 22_222.22,
        date: existing_entry.date,
        notes: "Nested upsert correction",
        upsert: "true"
      }
    }

    assert_no_difference("@family.entries.valuations.count") do
      post api_v1_valuations_url,
           params: valuation_params,
           headers: api_headers(@api_key)
    end

    assert_response :ok
    response_data = JSON.parse(response.body)
    assert_equal existing_entry.id, response_data["id"]
    assert_equal "Nested upsert correction", response_data["notes"]
    assert_equal BigDecimal("22222.22"), existing_entry.reload.amount
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

  # ============================================================================
  # Family-sharing scope tests
  # ============================================================================
  #
  # `family_admin` (Bob) owns every account in `dylan_family`. `family_member`
  # (Jakob) is shared `depository` (full_control) and `credit_card` (read_only).
  # Every other account (`other_asset`, `investment`, etc.) is unshared.
  # `Api::V1::ValuationsController` must scope create/show/update through
  # `Account.accessible_by` / `Account.writable_by` so a member cannot mutate
  # an account they cannot see in the UI, and cannot mutate a read-only-shared
  # account through the API.

  test "should reject create on an unshared family account" do
    member_key = member_api_key(scopes: [ "read_write" ])
    unshared_account = accounts(:other_asset) # owned by family_admin, not shared

    assert_no_difference -> { unshared_account.entries.valuations.count } do
      post api_v1_valuations_url,
           params: {
             valuation: {
               account_id: unshared_account.id,
               amount: 12_345.67,
               date: Date.current.to_s
             }
           },
           headers: api_headers(member_key)
    end
    assert_response :not_found
  end

  test "should reject create on a read-only-shared family account" do
    member_key = member_api_key(scopes: [ "read_write" ])
    read_only_account = accounts(:credit_card) # shared :read_only with member

    assert_no_difference -> { read_only_account.entries.valuations.count } do
      post api_v1_valuations_url,
           params: {
             valuation: {
               account_id: read_only_account.id,
               amount: 100.00,
               date: Date.current.to_s
             }
           },
           headers: api_headers(member_key)
    end
    assert_response :not_found
  end

  test "should allow create on a full-control-shared family account" do
    member_key = member_api_key(scopes: [ "read_write" ])
    shared_account = accounts(:depository) # shared :full_control with member

    assert_difference -> { shared_account.entries.valuations.count }, 1 do
      post api_v1_valuations_url,
           params: {
             valuation: {
               account_id: shared_account.id,
               amount: 250.00,
               date: Date.current.to_s
             }
           },
           headers: api_headers(member_key)
    end
    assert_response :created
  end

  test "should reject show of valuation on an unshared family account" do
    member_key = member_api_key(scopes: [ "read_write" ])
    hidden_valuation = accounts(:other_asset).entries.valuations.first ||
                       accounts(:other_asset).entries.valuations.create!(
                         date: 5.days.ago.to_date,
                         amount: 999,
                         currency: "USD",
                         name: "Hidden valuation",
                         entryable: Valuation.new(kind: "reconciliation")
                       )

    get api_v1_valuation_url(hidden_valuation),
        headers: api_headers(member_key)
    assert_response :not_found
  end

  test "should reject update of valuation on a read-only-shared family account" do
    member_key = member_api_key(scopes: [ "read_write" ])
    read_only_account = accounts(:credit_card) # shared :read_only with member
    entry = read_only_account.entries.valuations.first ||
            read_only_account.entries.valuations.create!(
              date: 5.days.ago.to_date,
              amount: 500,
              currency: "USD",
              name: "Existing valuation",
              entryable: Valuation.new(kind: "reconciliation")
            )

    original_amount = entry.amount
    patch api_v1_valuation_url(entry),
          params: { valuation: { amount: 9_999.99, date: entry.date.to_s } },
          headers: api_headers(member_key)
    assert_response :forbidden
    assert_equal original_amount, entry.reload.amount
  end

  test "should allow show of valuation on a shared family account" do
    member_key = member_api_key(scopes: [ "read_write" ])
    shared_account = accounts(:depository) # shared :full_control with member
    entry = shared_account.entries.valuations.first ||
            shared_account.entries.valuations.create!(
              date: 5.days.ago.to_date,
              amount: 1_000,
              currency: "USD",
              name: "Shared valuation",
              entryable: Valuation.new(kind: "reconciliation")
            )

    get api_v1_valuation_url(entry), headers: api_headers(member_key)
    assert_response :success
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def member_api_key(scopes:)
      member = users(:family_member)
      member.api_keys.active.destroy_all
      key = ApiKey.create!(
        user: member,
        name: "Member Test Key #{SecureRandom.hex(4)}",
        scopes: scopes,
        source: "web",
        display_key: "test_member_#{SecureRandom.hex(8)}"
      )
      Redis.new.del("api_rate_limit:#{key.id}")
      key
    end
end
