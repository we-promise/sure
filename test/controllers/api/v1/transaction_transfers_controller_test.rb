# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionTransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

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

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    # Set up two unlinked transactions with opposite amounts on different accounts
    checking = @family.accounts.find_by!(accountable_type: "Depository")
    credit_card = @family.accounts.find_by!(accountable_type: "CreditCard")

    outflow_entry = checking.entries.create!(
      name: "CC payment",
      date: Date.current,
      amount: 150.00,
      currency: "USD",
      entryable: Transaction.new
    )
    inflow_entry = credit_card.entries.create!(
      name: "Payment received",
      date: Date.current,
      amount: -150.00,
      currency: "USD",
      entryable: Transaction.new
    )

    @outflow_transaction = outflow_entry.transaction
    @inflow_transaction = inflow_entry.transaction
  end

  test "links two transactions as a transfer" do
    assert_difference "Transfer.count", 1 do
      patch api_v1_transaction_transfer_url(@outflow_transaction),
            params: { transfer: { other_transaction_id: @inflow_transaction.id } },
            headers: api_headers(@api_key),
            as: :json
    end

    assert_response :ok

    response_data = JSON.parse(response.body)
    assert response_data["transfer"].present?, "Expected transfer in response"
    assert response_data["transfer"].key?("id")
    assert response_data["transfer"].key?("amount")
    assert response_data["transfer"].key?("currency")
    assert response_data["transfer"].key?("other_account")

    @outflow_transaction.reload
    @inflow_transaction.reload
    assert @outflow_transaction.transfer.present?
    assert @inflow_transaction.transfer.present?
    assert_equal @outflow_transaction.transfer, @inflow_transaction.transfer
  end

  test "correctly assigns inflow and outflow regardless of which transaction is specified first" do
    patch api_v1_transaction_transfer_url(@inflow_transaction),
          params: { transfer: { other_transaction_id: @outflow_transaction.id } },
          headers: api_headers(@api_key),
          as: :json

    assert_response :ok

    @inflow_transaction.reload
    transfer = @inflow_transaction.transfer
    assert_equal @inflow_transaction, transfer.inflow_transaction
    assert_equal @outflow_transaction, transfer.outflow_transaction
  end

  test "returns 404 when transaction not found" do
    patch api_v1_transaction_transfer_url("00000000-0000-0000-0000-000000000000"),
          params: { transfer: { other_transaction_id: @inflow_transaction.id } },
          headers: api_headers(@api_key),
          as: :json

    assert_response :not_found
  end

  test "returns 404 when other_transaction_id not found" do
    patch api_v1_transaction_transfer_url(@outflow_transaction),
          params: { transfer: { other_transaction_id: "00000000-0000-0000-0000-000000000000" } },
          headers: api_headers(@api_key),
          as: :json

    assert_response :not_found
  end

  test "returns 422 when other_transaction_id is missing" do
    patch api_v1_transaction_transfer_url(@outflow_transaction),
          params: { transfer: {} },
          headers: api_headers(@api_key),
          as: :json

    assert_response :unprocessable_entity
  end

  test "returns 422 when transaction is already linked to a transfer" do
    # Link them first
    patch api_v1_transaction_transfer_url(@outflow_transaction),
          params: { transfer: { other_transaction_id: @inflow_transaction.id } },
          headers: api_headers(@api_key),
          as: :json
    assert_response :ok

    # Create a new unlinked transaction and try to link the already-linked one
    another_account = @family.accounts.find_by!(accountable_type: "Depository")
    extra_entry = another_account.entries.create!(
      name: "Another transaction",
      date: Date.current,
      amount: -150.00,
      currency: "USD",
      entryable: Transaction.new
    )

    patch api_v1_transaction_transfer_url(@outflow_transaction),
          params: { transfer: { other_transaction_id: extra_entry.transaction.id } },
          headers: api_headers(@api_key),
          as: :json

    assert_response :unprocessable_entity
  end

  test "returns 401 without a valid API key" do
    patch api_v1_transaction_transfer_url(@outflow_transaction),
          params: { transfer: { other_transaction_id: @inflow_transaction.id } },
          headers: { "X-Api-Key" => "invalid-key" },
          as: :json

    assert_response :unauthorized
  end

  test "returns 403 with read-only API key" do
    patch api_v1_transaction_transfer_url(@outflow_transaction),
          params: { transfer: { other_transaction_id: @inflow_transaction.id } },
          headers: api_headers(@read_only_api_key),
          as: :json

    assert_response :forbidden
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
