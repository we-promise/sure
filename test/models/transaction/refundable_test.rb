require "test_helper"

class Transaction::RefundableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @purchase = create_transaction(amount: 1000, category: categories(:one))
    @credit = create_transaction(amount: -800, name: "Payment processor")
  end

  test "a partial refund preserves bank amounts and inherits the purchase category" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)

    assert @credit.transaction.reload.refund?
    assert_equal @purchase.transaction.category, @credit.transaction.category
    assert_equal(-800, @credit.reload.amount)
    assert_equal 1000, @purchase.reload.amount
    assert_equal Money.new(200, "USD"), @purchase.transaction.purchase_net_cost_money
    assert @credit.transaction.locked?(:kind)
    assert @credit.transaction.locked?(:category_id)
    assert @credit.user_modified?
  end

  test "multiple refunds can settle a purchase without equal individual amounts" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    create_transaction(amount: -200).transaction.mark_as_refund!(purchase: @purchase.transaction)

    assert_equal Money.new(0, "USD"), @purchase.transaction.purchase_net_cost_money
  end

  test "refunds can be classified without a known purchase and cleared" do
    @credit.transaction.mark_as_refund!
    assert @credit.transaction.reload.refund?
    assert_nil @credit.transaction.refund_of

    @credit.transaction.clear_refund!
    assert @credit.transaction.reload.standard?
  end

  test "rejects outflows and cross family purchase links" do
    assert_raises(ActiveRecord::RecordInvalid) { @purchase.transaction.mark_as_refund! }
    other_account = families(:empty).accounts.create!(name: "Other", currency: "USD", balance: 1000, accountable: Depository.new)
    other = create_transaction(account: other_account, amount: 1000)
    assert_raises(ActiveRecord::RecordInvalid) do
      @credit.transaction.mark_as_refund!(purchase: other.transaction)
    end
    assert @credit.transaction.reload.standard?
  end

  test "foreign currency refund uses its own dated rate for purchase net cost" do
    @credit.update!(currency: "EUR", date: Date.current - 2.days)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @credit.date, rate: 1.1)
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)

    assert_equal Money.new(120, "USD"), @purchase.transaction.purchase_net_cost_money
  end

  test "linked refunds cannot silently become transfers or be split" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    assert_not @credit.transaction.splittable?
    assert_not @purchase.transaction.splittable?
    assert_not @credit.transaction.update(kind: "funds_movement")
  end

  test "unpaired card payments can be corrected to refunds and restored" do
    credit = create_transaction(account: accounts(:credit_card), amount: -100, kind: "cc_payment")
    credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    assert credit.transaction.refund?
    credit.transaction.clear_refund!
    assert credit.transaction.reload.cc_payment?
  end

  test "deleting a purchase preserves the bank credit as an unlinked refund" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    @purchase.destroy!
    assert @credit.transaction.reload.refund?
    assert_nil @credit.transaction.refund_of
    assert_equal(-800, @credit.reload.amount)
  end

  test "marked refunds are excluded from automatic transfer matching" do
    @credit.transaction.mark_as_refund!
    create_transaction(account: accounts(:credit_card), amount: 800)
    candidates = @credit.account.family.transfer_match_candidates(inflow_transaction_id: @credit.transaction.id)
    assert_empty candidates
  end

  test "a refund larger than the purchase retains the actual credit" do
    @credit.update!(amount: -1020)
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    assert_equal Money.new(-20, "USD"), @purchase.transaction.purchase_net_cost_money
  end

  test "manual refund classification is protected from provider enrichment" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    @credit.transaction.enrich_attribute(:kind, "standard", source: "test")
    assert @credit.transaction.reload.refund?
  end
end
