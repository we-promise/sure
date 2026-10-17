require "test_helper"

class Rule::ActionExecutor::ExcludeTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @rule = rules(:one)
    @account = @family.accounts.create!(name: "Excludable", balance: 1000, currency: "USD", accountable: Depository.new)
  end

  def action
    Rule::Action.new(rule: @rule, action_type: "exclude_transaction", value: nil)
  end

  # Excluding an installment drops it out of income statement and budget
  # totals (both filter on entries.excluded) while the balance keeps counting
  # it, so the plan's schedule would no longer add up to anything. Skipped
  # silently, like the transfer conversion in SetAsTransferOrPayment.
  test "skips an emi_purchase transaction instead of excluding it" do
    entry = create_transaction(date: Date.current, account: @account, amount: 1200, name: "Laptop")
    EmiPlan.build!(entry: entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    result = nil
    assert_nothing_raised do
      result = action.apply(@account.transactions)
    end

    assert_equal 0, result
    assert_not entry.reload.excluded?
  end

  test "skips an individual emi_installment transaction instead of excluding it" do
    entry = create_transaction(date: Date.current, account: @account, amount: 1200, name: "Laptop")
    plan = EmiPlan.build!(entry: entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    installment_entry = plan.installment_entries.first

    result = nil
    assert_nothing_raised do
      result = action.apply(Transaction.where(id: installment_entry.transaction.id))
    end

    assert_equal 0, result
    assert_not installment_entry.reload.excluded?
  end

  test "skips an emi_fee transaction instead of excluding it" do
    entry = create_transaction(date: Date.current, account: @account, amount: 1200, name: "Laptop")
    plan = EmiPlan.build!(entry: entry, interest_rate: 0, tenure_months: 6, processing_fee: 50)
    fee_entry = plan.processing_fee_entry

    result = nil
    assert_nothing_raised do
      result = action.apply(Transaction.where(id: fee_entry.transaction.id))
    end

    assert_equal 0, result
    assert_not fee_entry.reload.excluded?
  end

  test "still excludes an ordinary transaction as before" do
    entry = create_transaction(date: Date.current, account: @account, amount: 1200, name: "Laptop")

    assert_equal 1, action.apply(Transaction.where(id: entry.transaction.id))
    assert entry.reload.excluded?
  end
end
