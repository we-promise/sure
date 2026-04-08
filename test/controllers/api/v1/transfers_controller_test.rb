# frozen_string_literal: true

require "test_helper"

class Api::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @other_family_user = users(:empty)

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

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
      source: "mobile"
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    # Create accounts owned by the test user's family
    @from_account = @family.accounts.create!(
      name: "Transfer From #{SecureRandom.hex(4)}",
      balance: 5000,
      currency: "USD",
      accountable: Depository.new
    )
    @to_account = @family.accounts.create!(
      name: "Transfer To #{SecureRandom.hex(4)}",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    # Create a transfer within the test user's family (not relying on fixtures)
    @transfer = Transfer::Creator.new(
      family: @family,
      source_account_id: @from_account.id,
      destination_account_id: @to_account.id,
      date: Date.current,
      amount: 200
    ).create
  end

  # ──────────────────────────────────────────────
  # INDEX
  # ──────────────────────────────────────────────

  test "index requires authentication" do
    get api_v1_transfers_url
    assert_response :unauthorized
  end

  test "index returns transfers with valid API key" do
    get api_v1_transfers_url, headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("transfers")
    assert data.key?("pagination")
    assert data["pagination"].key?("page")
    assert data["pagination"].key?("per_page")
    assert data["pagination"].key?("total_count")
    assert data["pagination"].key?("total_pages")
  end

  test "index works with read-only API key" do
    get api_v1_transfers_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "index supports pagination" do
    get api_v1_transfers_url, params: { page: 1, per_page: 5 }, headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 1, data["pagination"]["page"]
    assert_equal 5, data["pagination"]["per_page"]
  end

  test "index filters by account_id" do
    get api_v1_transfers_url,
        params: { account_id: @from_account.id },
        headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)
    assert data["transfers"].any?, "Should find transfers for the given account"
  end

  test "index filters by date range" do
    get api_v1_transfers_url,
        params: { start_date: 1.week.ago.to_date.iso8601, end_date: Date.current.iso8601 },
        headers: api_headers(@api_key)
    assert_response :success
  end

  test "index returns empty when filtering by non-existent account" do
    get api_v1_transfers_url,
        params: { account_id: SecureRandom.uuid },
        headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 0, data["transfers"].size
  end

  test "index returns 422 for invalid date format" do
    get api_v1_transfers_url,
        params: { start_date: "not-a-date" },
        headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    data = JSON.parse(response.body)
    assert_equal "validation_failed", data["error"]
  end

  test "index does not return transfers from other families" do
    other_family = @other_family_user.family
    other_from = other_family.accounts.create!(name: "Other Checking", balance: 1000, currency: "USD", accountable: Depository.new)
    other_to = other_family.accounts.create!(name: "Other Savings", balance: 0, currency: "USD", accountable: Depository.new)
    other_transfer = Transfer::Creator.new(
      family: other_family,
      source_account_id: other_from.id,
      destination_account_id: other_to.id,
      date: Date.current,
      amount: 50
    ).create

    get api_v1_transfers_url, headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)
    transfer_ids = data["transfers"].map { |t| t["id"] }
    assert_not_includes transfer_ids, other_transfer.id
  end

  # ──────────────────────────────────────────────
  # SHOW
  # ──────────────────────────────────────────────

  test "show requires authentication" do
    get api_v1_transfer_url(@transfer)
    assert_response :unauthorized
  end

  test "show returns transfer with valid API key" do
    get api_v1_transfer_url(@transfer), headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal @transfer.id, data["id"]
    assert data.key?("status")
    assert data.key?("date")
    assert data.key?("amount")
    assert data.key?("currency")
    assert data.key?("name")
    assert data.key?("transfer_type")
    assert data.key?("from_account")
    assert data.key?("to_account")
    assert data.key?("inflow_transaction")
    assert data.key?("outflow_transaction")
    assert data.key?("created_at")
    assert data.key?("updated_at")
  end

  test "show works with read-only API key" do
    get api_v1_transfer_url(@transfer), headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "show returns 404 for non-existent transfer" do
    get api_v1_transfer_url(id: SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "show returns 404 for transfer from another family" do
    other_family = @other_family_user.family
    other_from = other_family.accounts.create!(name: "Other Checking", balance: 1000, currency: "USD", accountable: Depository.new)
    other_to = other_family.accounts.create!(name: "Other Savings", balance: 0, currency: "USD", accountable: Depository.new)
    other_transfer = Transfer::Creator.new(
      family: other_family,
      source_account_id: other_from.id,
      destination_account_id: other_to.id,
      date: Date.current,
      amount: 50
    ).create

    get api_v1_transfer_url(other_transfer), headers: api_headers(@api_key)
    assert_response :not_found
  end

  # ──────────────────────────────────────────────
  # CREATE
  # ──────────────────────────────────────────────

  test "create requires authentication" do
    post api_v1_transfers_url,
         params: { transfer: { from_account_id: @from_account.id, to_account_id: @to_account.id, amount: 100, date: Date.current } }
    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    post api_v1_transfers_url,
         params: { transfer: { from_account_id: @from_account.id, to_account_id: @to_account.id, amount: 100, date: Date.current } },
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "create transfer successfully" do
    from = @family.accounts.create!(name: "API From #{SecureRandom.hex(4)}", balance: 5000, currency: "USD", accountable: Depository.new)
    to = @family.accounts.create!(name: "API To #{SecureRandom.hex(4)}", balance: 0, currency: "USD", accountable: Depository.new)

    assert_difference "Transfer.count", 1 do
      post api_v1_transfers_url,
           params: { transfer: { from_account_id: from.id, to_account_id: to.id, amount: 250.00, date: Date.current.iso8601 } },
           headers: api_headers(@api_key)
    end

    assert_response :created

    data = JSON.parse(response.body)
    assert data["id"].present?
    assert_equal "confirmed", data["status"]
    assert_equal from.id, data["from_account"]["id"]
    assert_equal to.id, data["to_account"]["id"]
    assert_equal "transfer", data["transfer_type"]
  end

  test "create transfer to credit card sets liability_payment type" do
    from = @family.accounts.create!(name: "Pay From #{SecureRandom.hex(4)}", balance: 5000, currency: "USD", accountable: Depository.new)
    cc = @family.accounts.create!(name: "CC #{SecureRandom.hex(4)}", balance: 1000, currency: "USD", accountable: CreditCard.new)

    post api_v1_transfers_url,
         params: { transfer: { from_account_id: from.id, to_account_id: cc.id, amount: 200, date: Date.current.iso8601 } },
         headers: api_headers(@api_key)

    assert_response :created
    data = JSON.parse(response.body)
    assert_equal "liability_payment", data["transfer_type"]
  end

  test "create fails without from_account_id and to_account_id" do
    post api_v1_transfers_url,
         params: { transfer: { from_account_id: @from_account.id } },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    data = JSON.parse(response.body)
    assert_equal "validation_failed", data["error"]
  end

  test "create fails without amount and date" do
    post api_v1_transfers_url,
         params: { transfer: { from_account_id: @from_account.id, to_account_id: @to_account.id } },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "create fails with invalid date format" do
    post api_v1_transfers_url,
         params: { transfer: { from_account_id: @from_account.id, to_account_id: @to_account.id, amount: 100, date: "invalid-date" } },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    data = JSON.parse(response.body)
    assert_equal "validation_failed", data["error"]
    assert_equal "Invalid date format", data["message"]
  end

  test "create fails with non-existent account" do
    post api_v1_transfers_url,
         params: { transfer: { from_account_id: SecureRandom.uuid, to_account_id: @to_account.id, amount: 100, date: Date.current.iso8601 } },
         headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "create fails with account from another family" do
    other_family = @other_family_user.family
    other_account = other_family.accounts.create!(name: "Other Account", balance: 1000, currency: "USD", accountable: Depository.new)

    post api_v1_transfers_url,
         params: { transfer: { from_account_id: other_account.id, to_account_id: @to_account.id, amount: 100, date: Date.current.iso8601 } },
         headers: api_headers(@api_key)
    assert_response :not_found
  end

  # ──────────────────────────────────────────────
  # UPDATE
  # ──────────────────────────────────────────────

  test "update requires authentication" do
    patch api_v1_transfer_url(@transfer), params: { transfer: { status: "confirmed" } }
    assert_response :unauthorized
  end

  test "update requires read_write scope" do
    patch api_v1_transfer_url(@transfer),
          params: { transfer: { status: "confirmed" } },
          headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "update confirms a pending transfer" do
    @transfer.update!(status: "pending")

    patch api_v1_transfer_url(@transfer),
          params: { transfer: { status: "confirmed" } },
          headers: api_headers(@api_key)

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal "confirmed", data["status"]
  end

  test "update rejects a transfer" do
    from = @family.accounts.create!(name: "Rej From #{SecureRandom.hex(4)}", balance: 5000, currency: "USD", accountable: Depository.new)
    to = @family.accounts.create!(name: "Rej To #{SecureRandom.hex(4)}", balance: 0, currency: "USD", accountable: Depository.new)
    transfer = Transfer::Creator.new(family: @family, source_account_id: from.id, destination_account_id: to.id, date: Date.current, amount: 100).create

    patch api_v1_transfer_url(transfer),
          params: { transfer: { status: "rejected" } },
          headers: api_headers(@api_key)

    assert_response :success
    assert_equal({ "message" => "Transfer rejected" }, JSON.parse(response.body))
    assert_nil Transfer.find_by(id: transfer.id), "Transfer should be destroyed after rejection"
  end

  test "update returns 422 for invalid status" do
    patch api_v1_transfer_url(@transfer),
          params: { transfer: { status: "bogus" } },
          headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    data = JSON.parse(response.body)
    assert_equal "validation_failed", data["error"]
  end

  test "update notes on a transfer" do
    patch api_v1_transfer_url(@transfer),
          params: { transfer: { notes: "Monthly rent payment" } },
          headers: api_headers(@api_key)

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal "Monthly rent payment", data["notes"]
  end

  test "update can clear notes with empty string" do
    @transfer.update!(notes: "Some notes")

    patch api_v1_transfer_url(@transfer),
          params: { transfer: { notes: "" } },
          headers: api_headers(@api_key)

    assert_response :success
    @transfer.reload
    assert_equal "", @transfer.notes
  end

  test "update without notes key preserves existing notes" do
    @transfer.update!(notes: "Existing notes")

    patch api_v1_transfer_url(@transfer),
          params: { transfer: { status: "confirmed" } },
          headers: api_headers(@api_key)

    assert_response :success
    @transfer.reload
    assert_equal "Existing notes", @transfer.notes
  end

  test "update returns 404 for non-existent transfer" do
    patch api_v1_transfer_url(id: SecureRandom.uuid),
          params: { transfer: { notes: "test" } },
          headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "update returns 404 for transfer from another family" do
    other_family = @other_family_user.family
    other_from = other_family.accounts.create!(name: "Other Checking", balance: 1000, currency: "USD", accountable: Depository.new)
    other_to = other_family.accounts.create!(name: "Other Savings", balance: 0, currency: "USD", accountable: Depository.new)
    other_transfer = Transfer::Creator.new(
      family: other_family,
      source_account_id: other_from.id,
      destination_account_id: other_to.id,
      date: Date.current,
      amount: 50
    ).create

    patch api_v1_transfer_url(other_transfer),
          params: { transfer: { notes: "hacker" } },
          headers: api_headers(@api_key)
    assert_response :not_found
  end

  # ──────────────────────────────────────────────
  # DESTROY
  # ──────────────────────────────────────────────

  test "destroy requires authentication" do
    delete api_v1_transfer_url(@transfer)
    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    delete api_v1_transfer_url(@transfer), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "destroy transfer successfully" do
    from = @family.accounts.create!(name: "Del From #{SecureRandom.hex(4)}", balance: 5000, currency: "USD", accountable: Depository.new)
    to = @family.accounts.create!(name: "Del To #{SecureRandom.hex(4)}", balance: 0, currency: "USD", accountable: Depository.new)
    transfer = Transfer::Creator.new(family: @family, source_account_id: from.id, destination_account_id: to.id, date: Date.current, amount: 100).create

    assert_difference "Transfer.count", -1 do
      delete api_v1_transfer_url(transfer), headers: api_headers(@api_key)
    end

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal "Transfer deleted successfully", data["message"]
  end

  test "destroy marks linked transactions as standard" do
    from = @family.accounts.create!(name: "Std From #{SecureRandom.hex(4)}", balance: 5000, currency: "USD", accountable: Depository.new)
    to = @family.accounts.create!(name: "Std To #{SecureRandom.hex(4)}", balance: 0, currency: "USD", accountable: Depository.new)
    transfer = Transfer::Creator.new(family: @family, source_account_id: from.id, destination_account_id: to.id, date: Date.current, amount: 100).create

    inflow_id = transfer.inflow_transaction_id
    outflow_id = transfer.outflow_transaction_id

    delete api_v1_transfer_url(transfer), headers: api_headers(@api_key)
    assert_response :success

    assert_equal "standard", Transaction.find(inflow_id).kind
    assert_equal "standard", Transaction.find(outflow_id).kind
  end

  test "destroy returns 404 for non-existent transfer" do
    delete api_v1_transfer_url(id: SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "destroy returns 404 for transfer from another family" do
    other_family = @other_family_user.family
    other_from = other_family.accounts.create!(name: "Other Checking", balance: 1000, currency: "USD", accountable: Depository.new)
    other_to = other_family.accounts.create!(name: "Other Savings", balance: 0, currency: "USD", accountable: Depository.new)
    other_transfer = Transfer::Creator.new(
      family: other_family,
      source_account_id: other_from.id,
      destination_account_id: other_to.id,
      date: Date.current,
      amount: 50
    ).create

    assert_no_difference "Transfer.count" do
      delete api_v1_transfer_url(other_transfer), headers: api_headers(@api_key)
    end
    assert_response :not_found
  end

  # ──────────────────────────────────────────────
  # JSON structure
  # ──────────────────────────────────────────────

  test "transfer JSON has expected structure" do
    get api_v1_transfer_url(@transfer), headers: api_headers(@api_key)
    assert_response :success

    data = JSON.parse(response.body)

    # Core fields
    assert data.key?("id")
    assert data.key?("status")
    assert data.key?("date")
    assert data.key?("amount")
    assert data.key?("currency")
    assert data.key?("name")
    assert data.key?("transfer_type")
    assert data.key?("notes")

    # Account references
    assert data.key?("from_account")
    assert data["from_account"].key?("id")
    assert data["from_account"].key?("name")
    assert data["from_account"].key?("account_type")

    assert data.key?("to_account")
    assert data["to_account"].key?("id")
    assert data["to_account"].key?("name")
    assert data["to_account"].key?("account_type")

    # Transaction references
    assert data.key?("inflow_transaction")
    assert data["inflow_transaction"].key?("id")
    assert data["inflow_transaction"].key?("entry_id")
    assert data["inflow_transaction"].key?("amount")
    assert data["inflow_transaction"].key?("currency")

    assert data.key?("outflow_transaction")
    assert data["outflow_transaction"].key?("id")
    assert data["outflow_transaction"].key?("entry_id")
    assert data["outflow_transaction"].key?("amount")
    assert data["outflow_transaction"].key?("currency")

    # Optional
    assert data.key?("category")
    assert data.key?("created_at")
    assert data.key?("updated_at")
  end

  test "error responses do not leak internal details" do
    # Trigger an internal error by passing something that would cause a StandardError
    # The 500 response should say "An unexpected error occurred", not the actual error
    get api_v1_transfer_url(id: SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found

    data = JSON.parse(response.body)
    assert_equal "not_found", data["error"]
    assert_equal "Transfer not found", data["message"]
    assert_not data["message"].include?("ActiveRecord"), "Error should not leak internal class names"
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
