require "test_helper"

class Rule::ActionExecutor::SetAsTransferOrPaymentTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @rule = rules(:one)
    @source_account = @family.accounts.create!(name: "Source", balance: 1000, currency: "USD", accountable: Depository.new)
    @target_account = @family.accounts.create!(name: "Target", balance: 1000, currency: "USD", accountable: Depository.new)
  end

  def action
    Rule::Action.new(rule: @rule, action_type: "set_as_transfer_or_payment", value: @target_account.id.to_s)
  end

  test "skips an emi_purchase transaction instead of raising" do
    entry = create_transaction(date: Date.current, account: @source_account, amount: 1200, name: "Laptop")
    EmiPlan.build!(entry: entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    result = nil
    assert_nothing_raised do
      result = action.apply(@source_account.transactions)
    end

    assert_equal 0, result
    assert_equal "emi_purchase", entry.reload.transaction.kind
    refute entry.transaction.transfer?
  end

  test "skips an individual emi_installment transaction instead of raising" do
    entry = create_transaction(date: Date.current, account: @source_account, amount: 1200, name: "Laptop")
    plan = EmiPlan.build!(entry: entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    installment_entry = plan.installment_entries.first

    result = nil
    assert_nothing_raised do
      result = action.apply(Transaction.where(id: installment_entry.transaction.id))
    end

    assert_equal 0, result
    assert_equal "emi_installment", installment_entry.reload.transaction.kind
  end

  test "skips an emi_fee transaction instead of raising" do
    entry = create_transaction(date: Date.current, account: @source_account, amount: 1200, name: "Laptop")
    plan = EmiPlan.build!(entry: entry, interest_rate: 0, tenure_months: 6, processing_fee: 50)
    fee_entry = plan.processing_fee_entry

    result = nil
    assert_nothing_raised do
      result = action.apply(Transaction.where(id: fee_entry.transaction.id))
    end

    assert_equal 0, result
    assert_equal "emi_fee", fee_entry.reload.transaction.kind
    refute fee_entry.transaction.transfer?
  end

  test "still converts an ordinary transaction to a transfer as before" do
    entry = create_transaction(date: Date.current, account: @source_account, amount: 500, name: "Rent")

    result = action.apply(@source_account.transactions.where(id: entry.transaction.id))

    assert_equal 1, result
    assert entry.reload.transaction.transfer?
  end
end
