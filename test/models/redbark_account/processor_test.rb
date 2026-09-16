# frozen_string_literal: true

require "test_helper"

class RedbarkAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_account.redbark_item.family

    @account = @family.accounts.create!(
      name: "Test Account",
      balance: 1000,
      currency: "AUD",
      accountable: Depository.new
    )

    @redbark_account.ensure_account_provider!(@account)
    @redbark_account.reload
  end

  test "processor initializes with redbark_account" do
    processor = RedbarkAccount::Processor.new(@redbark_account)
    assert_not_nil processor
  end

  test "processor skips processing when no linked account" do
    @redbark_account.account_provider&.destroy
    @redbark_account.reload

    processor = RedbarkAccount::Processor.new(@redbark_account)
    assert_nothing_raised { processor.process }
  end

  test "processor updates account balance" do
    @redbark_account.update!(current_balance: 15000)

    RedbarkAccount::Processor.new(@redbark_account).process

    @account.reload
    assert_equal 15000, @account.balance.to_f
  end

  test "processor negates balance for credit card accounts" do
    credit_account = @family.accounts.create!(
      name: "Test Credit Card",
      balance: 0,
      currency: "AUD",
      accountable: CreditCard.new
    )
    @redbark_account.account_provider&.destroy
    @redbark_account.reload
    @redbark_account.ensure_account_provider!(credit_account)
    @redbark_account.update!(current_balance: -250)

    RedbarkAccount::Processor.new(@redbark_account).process

    credit_account.reload
    assert_equal 250, credit_account.balance.to_f
  end

  test "transactions processor creates entries from raw payload" do
    @redbark_account.update!(raw_transactions_payload: [
      {
        "id" => "tx_001",
        "accountId" => @redbark_account.redbark_account_id,
        "status" => "posted",
        "date" => Date.current.to_s,
        "description" => "COFFEE SHOP SYDNEY",
        "amount" => "-4.50",
        "direction" => "debit",
        "merchantName" => "Coffee Shop"
      }
    ])

    result = RedbarkAccount::Transactions::Processor.new(@redbark_account).process

    assert result[:success]
    assert_equal 1, result[:imported]

    entry = @account.entries.find_by(external_id: "redbark_tx_001", source: "redbark")
    assert_not_nil entry
    # Redbark amounts are CDR pre-signed (negative = money out); Sure stores the opposite sign
    assert_equal 4.50, entry.amount.to_f
    assert_equal "Coffee Shop", entry.name
    assert_equal "AUD", entry.currency
  end

  test "transactions processor stores pending flag in extra metadata" do
    @redbark_account.update!(raw_transactions_payload: [
      {
        "id" => "tx_002",
        "status" => "pending",
        "date" => Date.current.to_s,
        "description" => "PENDING PURCHASE",
        "amount" => "-10.00",
        "direction" => "debit"
      }
    ])

    RedbarkAccount::Transactions::Processor.new(@redbark_account).process

    entry = @account.entries.find_by(external_id: "redbark_tx_002", source: "redbark")
    assert_not_nil entry
    assert_equal true, entry.entryable.extra.dig("redbark", "pending")
  end

  test "transactions processor handles missing transaction id gracefully" do
    @redbark_account.update!(raw_transactions_payload: [
      { "id" => nil, "amount" => "-50.00", "date" => Date.current.to_s }
    ])

    result = RedbarkAccount::Transactions::Processor.new(@redbark_account).process

    assert result[:success]
    assert_equal 1, result[:skipped]
    assert_equal 0, result[:failed]
  end

  test "transactions processor returns empty result when no transactions" do
    @redbark_account.update!(raw_transactions_payload: [])

    result = RedbarkAccount::Transactions::Processor.new(@redbark_account).process

    assert result[:success]
    assert_equal 0, result[:total]
  end
end
