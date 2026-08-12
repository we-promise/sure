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

  private

    def create_account(name)
      @family.accounts.create!(
        name: name, balance: 0, currency: "USD",
        accountable: Depository.new(subtype: "checking")
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
