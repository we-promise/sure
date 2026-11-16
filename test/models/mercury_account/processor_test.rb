# frozen_string_literal: true

require "test_helper"

class MercuryAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family   = families(:dylan_family)
    @item     = MercuryItem.create!(family: @family, name: "Mercury", token: "tok")
  end

  # ---------------------------------------------------------------------------
  # balance update
  # ---------------------------------------------------------------------------

  test "updates account balance from mercury_account current_balance" do
    account         = create_account("Checking")
    mercury_account = create_mercury_account("acc_001", balance: 12_345.67, account: account)

    MercuryAccount::Processor.new(mercury_account).process

    assert_in_delta 12_345.67, account.reload.balance, 0.01
  end

  test "negates balance for CreditCard accounts" do
    account         = @family.accounts.create!(
      name: "Mercury Credit", balance: 0, currency: "USD",
      accountable: CreditCard.new
    )
    mercury_account = create_mercury_account("acc_credit", balance: 500.0, account: account)

    MercuryAccount::Processor.new(mercury_account).process

    assert_in_delta(-500.0, account.reload.balance, 0.01)
  end

  test "sets cash_balance equal to balance for depository" do
    account         = create_account("Savings")
    mercury_account = create_mercury_account("acc_002", balance: 3_000.0, account: account)

    MercuryAccount::Processor.new(mercury_account).process

    assert_in_delta 3_000.0, account.reload.cash_balance, 0.01
  end

  # ---------------------------------------------------------------------------
  # no linked account
  # ---------------------------------------------------------------------------

  test "returns nil without error when no linked account" do
    mercury_account = @item.mercury_accounts.create!(
      name: "Unlinked", account_id: "acc_unlinked", currency: "USD", current_balance: 100
    )

    result = nil
    assert_nothing_raised do
      result = MercuryAccount::Processor.new(mercury_account).process
    end
    assert_nil result
  end

  # ---------------------------------------------------------------------------
  # transaction processing delegation
  # ---------------------------------------------------------------------------

  test "processes transactions stored in raw_transactions_payload" do
    account = create_account("Checking")
    mercury_account = create_mercury_account("acc_003", balance: 0, account: account,
      raw_transactions: [
        { "id" => "tx_a", "amount" => 100.0, "status" => "sent",
          "bankDescription" => "Deposit", "createdAt" => "2024-06-01T00:00:00Z",
          "postedAt" => "2024-06-01T00:00:00Z" }
      ]
    )

    assert_difference "account.entries.count", 1 do
      MercuryAccount::Processor.new(mercury_account).process
    end
  end

  test "removes an imported entry once its transaction is stored as failed" do
    account = create_account("Checking")
    mercury_account = create_mercury_account("acc_004", balance: 0, account: account,
      raw_transactions: [ raw_transaction("tx_a", status: "pending") ])

    assert_difference "account.entries.count", 1 do
      MercuryAccount::Processor.new(mercury_account).process
    end

    mercury_account.update!(raw_transactions_payload: [ raw_transaction("tx_a", status: "failed") ])

    assert_difference "account.entries.count", -1 do
      MercuryAccount::Processor.new(mercury_account).process
    end
  end

  test "counts a removed unsettled transaction as skipped, not failed" do
    account = create_account("Checking")
    mercury_account = create_mercury_account("acc_005", balance: 0, account: account,
      raw_transactions: [ raw_transaction("tx_a", status: "pending") ])
    MercuryAccount::Processor.new(mercury_account).process

    mercury_account.update!(raw_transactions_payload: [
      raw_transaction("tx_a", status: "reversed"),
      raw_transaction("tx_b", status: "sent")
    ])
    result = MercuryAccount::Transactions::Processor.new(mercury_account).process

    assert result[:success]
    assert_equal 2, result[:total]
    assert_equal 1, result[:imported]
    assert_equal 1, result[:skipped]
    assert_equal 0, result[:failed]
    assert_empty result[:errors]
  end

  test "still counts a transaction without a linked account as failed" do
    mercury_account = create_unlinked_mercury_account("acc_006", raw_transactions: [ raw_transaction("tx_a", status: "sent") ])

    result = MercuryAccount::Transactions::Processor.new(mercury_account).process

    assert_not result[:success]
    assert_equal 1, result[:failed]
    assert_equal 0, result[:skipped]
    assert_equal "No linked account", result[:errors].first[:error]
  end

  private

    def raw_transaction(id, status:)
      { "id" => id, "amount" => 100.0, "status" => status,
        "bankDescription" => "Deposit", "createdAt" => "2024-06-01T00:00:00Z",
        "postedAt" => "2024-06-01T00:00:00Z" }
    end

    def create_account(name)
      @family.accounts.create!(
        name: name, balance: 0, currency: "USD",
        accountable: Depository.new(subtype: "checking")
      )
    end

    def create_unlinked_mercury_account(account_id, raw_transactions: [])
      @item.mercury_accounts.create!(
        name: account_id, account_id: account_id, currency: "USD",
        current_balance: 0, raw_transactions_payload: raw_transactions
      )
    end

    def create_mercury_account(account_id, balance:, account:, raw_transactions: [])
      ma = @item.mercury_accounts.create!(
        name: account_id, account_id: account_id, currency: "USD",
        current_balance: balance,
        raw_transactions_payload: raw_transactions
      )
      AccountProvider.create!(provider: ma, account: account)
      ma
    end
end
