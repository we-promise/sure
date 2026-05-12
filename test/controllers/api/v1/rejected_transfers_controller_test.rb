# frozen_string_literal: true

require "test_helper"

class Api::V1::RejectedTransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = @family.accounts.create!(
      name: "Rejected Checking",
      accountable: Depository.new,
      balance: 500,
      currency: "USD"
    )
    @destination_account = @family.accounts.create!(
      name: "Rejected Savings",
      accountable: Depository.new,
      balance: 1000,
      currency: "USD"
    )

    outflow = create_transaction(@account, amount: 25, date: Date.parse("2024-01-15"), name: "Rejected outflow")
    inflow = create_transaction(@destination_account, amount: -25, date: Date.parse("2024-01-15"), name: "Rejected inflow")
    @rejected_transfer = RejectedTransfer.create!(
      outflow_transaction: outflow,
      inflow_transaction: inflow
    )

    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other Rejected Checking", accountable: Depository.new, balance: 0, currency: "USD")
    other_destination = other_family.accounts.create!(name: "Other Rejected Savings", accountable: Depository.new, balance: 0, currency: "USD")
    other_outflow = create_transaction(other_account, amount: 50, date: Date.parse("2024-01-15"), name: "Other rejected outflow")
    other_inflow = create_transaction(other_destination, amount: -50, date: Date.parse("2024-01-15"), name: "Other rejected inflow")
    @other_rejected_transfer = RejectedTransfer.create!(outflow_transaction: other_outflow, inflow_transaction: other_inflow)
  end

  test "lists rejected transfers scoped to the current family" do
    get api_v1_rejected_transfers_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("rejected_transfers")
    assert response_data.key?("pagination")
    assert_includes response_data["rejected_transfers"].map { |transfer| transfer["id"] }, @rejected_transfer.id
    assert_not_includes response_data["rejected_transfers"].map { |transfer| transfer["id"] }, @other_rejected_transfer.id
  end

  test "permits read write scope" do
    read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_read_write_#{SecureRandom.hex(8)}"
    )

    get api_v1_rejected_transfers_url, headers: api_headers(read_write_key)

    assert_response :success
  end

  test "shows a rejected transfer" do
    get api_v1_rejected_transfer_url(@rejected_transfer), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @rejected_transfer.id, response_data["id"]
    assert_equal "Rejected Savings", response_data.dig("inflow_transaction", "account", "name")
    assert_equal "Rejected Checking", response_data.dig("outflow_transaction", "account", "name")
  end

  test "returns not found for another family's rejected transfer" do
    get api_v1_rejected_transfer_url(@other_rejected_transfer), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed rejected transfer id" do
    get api_v1_rejected_transfer_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters rejected transfers by account_id" do
    get api_v1_rejected_transfers_url, params: { account_id: @account.id }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["rejected_transfers"].map { |transfer| transfer["id"] }, @rejected_transfer.id
  end

  test "rejects malformed account_id filter" do
    get api_v1_rejected_transfers_url, params: { account_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filter" do
    get api_v1_rejected_transfers_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "filters rejected transfers when either transaction side date matches" do
    matched_outflow = create_transaction(@account, amount: 35, date: Date.parse("2024-02-10"), name: "Rejected dated outflow")
    matched_inflow = create_transaction(@destination_account, amount: -35, date: Date.parse("2024-02-10"), name: "Rejected dated inflow")
    date_matched_transfer = RejectedTransfer.create!(outflow_transaction: matched_outflow, inflow_transaction: matched_inflow)

    partial_outflow = create_transaction(@account, amount: 45, date: Date.parse("2024-02-10"), name: "Rejected partial outflow")
    partial_inflow = create_transaction(@destination_account, amount: -45, date: Date.parse("2024-02-12"), name: "Rejected partial inflow")
    partial_date_transfer = RejectedTransfer.create!(outflow_transaction: partial_outflow, inflow_transaction: partial_inflow)

    get api_v1_rejected_transfers_url,
        params: { start_date: "2024-02-10", end_date: "2024-02-10" },
        headers: api_headers(@api_key)

    assert_response :success
    transfer_ids = JSON.parse(response.body)["rejected_transfers"].map { |transfer| transfer["id"] }
    assert_includes transfer_ids, date_matched_transfer.id
    assert_includes transfer_ids, partial_date_transfer.id
    assert_not_includes transfer_ids, @rejected_transfer.id
  end

  test "requires authentication" do
    get api_v1_rejected_transfers_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    # ApiKey.create! rejects empty scopes; bypass validation to exercise runtime authorization.
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_rejected_transfers_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  private

    def create_transaction(account, amount:, date:, name:)
      entry = account.entries.create!(
        date: date,
        amount: amount,
        name: name,
        currency: account.currency,
        entryable: Transaction.new(kind: "standard")
      )
      entry.entryable
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
