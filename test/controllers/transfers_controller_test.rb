require "test_helper"

class TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "should get new" do
    get new_transfer_url
    assert_response :success
  end

  test "can create transfers" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          name: "Test Transfer"
        }
      }
      assert_enqueued_with job: SyncJob
    end
  end

  test "can create transfer with custom exchange rate" do
    usd_account = accounts(:depository)
    eur_account = users(:family_admin).family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    assert_equal "USD", usd_account.currency
    assert_equal "EUR", eur_account.currency

    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: usd_account.id,
          to_account_id: eur_account.id,
          date: Date.current,
          amount: 100,
          exchange_rate: 0.92
        }
      }
    end

    transfer = Transfer.where(
      "outflow_transaction_id IN (?) AND inflow_transaction_id IN (?)",
      usd_account.transactions.pluck(:id),
      eur_account.transactions.pluck(:id)
    ).last
    assert_not_nil transfer
    assert_equal "USD", transfer.outflow_transaction.entry.currency
    assert_equal "EUR", transfer.inflow_transaction.entry.currency
    assert_equal 100, transfer.outflow_transaction.entry.amount
    assert_in_delta(-92, transfer.inflow_transaction.entry.amount, 0.01)
  end

  test "exchange_rate endpoint returns rate for different currencies" do
    usd_account = accounts(:depository)
    eur_account = users(:family_admin).family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "EUR", date: Date.current)
                .returns(OpenStruct.new(rate: 0.92))

    get exchange_rate_transfers_url, params: {
      from_account_id: usd_account.id,
      to_account_id: eur_account.id,
      date: Date.current.to_s
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 0.92, json_response["rate"]
    assert_equal false, json_response["same_currency"]
    assert_equal "USD", json_response["from_currency"]
    assert_equal "EUR", json_response["to_currency"]
  end

  test "exchange_rate endpoint returns same_currency for matching currencies" do
    usd_account_1 = accounts(:depository)
    usd_account_2 = accounts(:investment)

    get exchange_rate_transfers_url, params: {
      from_account_id: usd_account_1.id,
      to_account_id: usd_account_2.id
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_nil json_response["rate"]
    assert_equal true, json_response["same_currency"]
  end

  test "exchange_rate endpoint returns 404 for invalid account" do
    get exchange_rate_transfers_url, params: {
      from_account_id: 99999,
      to_account_id: accounts(:depository).id
    }

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "Account not found", json_response["error"]
  end

  test "exchange_rate endpoint handles invalid date" do
    get exchange_rate_transfers_url, params: {
      from_account_id: accounts(:depository).id,
      to_account_id: accounts(:credit_card).id,
      date: "invalid-date"
    }

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "Invalid date", json_response["error"]
  end

  test "soft deletes transfer" do
    assert_difference -> { Transfer.count }, -1 do
      delete transfer_url(transfers(:one))
    end
  end

  test "can add notes to transfer" do
    transfer = transfers(:one)
    assert_nil transfer.notes

    patch transfer_url(transfer), params: { transfer: { notes: "Test notes" } }

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]
    assert_equal "Test notes", transfer.reload.notes
  end

  test "handles rejection without FrozenError" do
    transfer = transfers(:one)

    assert_difference "Transfer.count", -1 do
      patch transfer_url(transfer), params: {
        transfer: {
          status: "rejected"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]

    # Verify the transfer was actually destroyed
    assert_raises(ActiveRecord::RecordNotFound) do
      transfer.reload
    end
  end
end
