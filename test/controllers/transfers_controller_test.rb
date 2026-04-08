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

  test "exchange_rate endpoint returns 400 when from currency is missing" do
    get exchange_rate_url, params: {
      to: "USD"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "exchange_rate endpoint returns 400 when to currency is missing" do
    get exchange_rate_url, params: {
      from: "EUR"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "exchange_rate endpoint returns 400 on invalid date format" do
    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: "not-a-date"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "Invalid date format", json_response["error"]
  end

  test "exchange_rate endpoint returns rate for different currencies" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "EUR", date: Date.current)
                .returns(OpenStruct.new(rate: 0.92))

    get exchange_rate_url, params: {
      from: "USD",
      to: "EUR",
      date: Date.current.to_s
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 0.92, json_response["rate"]
  end

  test "exchange_rate endpoint returns error when exchange rate unavailable" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "EUR", date: Date.current)
                .returns(nil)

    get exchange_rate_url, params: {
      from: "USD",
      to: "EUR",
      date: Date.current.to_s
    }

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "Exchange rate not found", json_response["error"]
  end

  test "cannot create transfer when exchange rate unavailable and no custom rate provided" do
    usd_account = accounts(:depository)
    eur_account = users(:family_admin).family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_no_difference "Transfer.count" do
      post transfers_url, params: {
        transfer: {
          from_account_id: usd_account.id,
          to_account_id: eur_account.id,
          date: Date.current,
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "exchange_rate endpoint returns same_currency for matching currencies" do
    get exchange_rate_url, params: {
      from: "USD",
      to: "USD"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal true, json_response["same_currency"]
    assert_equal 1.0, json_response["rate"]
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
