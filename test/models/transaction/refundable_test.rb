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

  test "linked purchases must be unlinked before exclusion" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)

    assert_not @purchase.update(excluded: true)
    assert_not @purchase.reload.excluded?
    assert @credit.transaction.update(category: categories(:food_and_drink))

    @credit.transaction.clear_refund!
    assert @purchase.update(excluded: true)
  end

  test "a purchase that drifts out of linkable state does not brick its refund" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    # Entry validations block the UI toggle, but Entry.auto_exclude_stale_pending
    # writes through update_all, so the drift is still reachable.
    @purchase.update_column(:excluded, true)

    refund = @credit.transaction.reload
    assert refund.update(merchant: nil, category: categories(:food_and_drink)),
      refund.errors.full_messages.to_sentence
    assert refund.reload.refund?
    assert_equal @purchase.transaction, refund.refund_of
  end

  test "a purchase that is not linkable cannot be linked in the first place" do
    @purchase.update_column(:excluded, true)

    assert_raises(ActiveRecord::RecordInvalid) do
      @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    end
    assert @credit.transaction.reload.standard?
  end

  test "dropping refund classification while a purchase link remains is still rejected" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    refund = @credit.transaction.reload

    assert_not refund.update(kind: "standard")
    assert refund.errors.of_kind?(:refund_of, :invalid)
  end

  test "an uncategorized purchase preserves the refund category and enrichment eligibility" do
    @purchase.transaction.update!(category: nil)
    @credit.transaction.update!(category: categories(:food_and_drink))

    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)

    assert_equal categories(:food_and_drink), @credit.transaction.reload.category
    assert_not @credit.transaction.locked?(:category_id)
    @credit.transaction.enrich_attribute(:category_id, categories(:one).id, source: "plaid")
    assert_equal categories(:one), @credit.transaction.reload.category
  end

  test "clearing a refund preserves the explicit classification against provider enrichment" do
    @credit.transaction.mark_as_refund!
    @credit.transaction.clear_refund!
    @credit.transaction.enrich_attribute(:kind, "cc_payment", source: "plaid")

    assert @credit.transaction.reload.standard?
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

  test "linked purchases are excluded from same and cross currency transfer matching" do
    same_currency = create_transaction(account: accounts(:credit_card), amount: -1000)
    foreign_currency = create_transaction(account: accounts(:credit_card), amount: -900, currency: "EUR")
    ExchangeRate.find_or_initialize_by(from_currency: "USD", to_currency: "EUR", date: @purchase.date).update!(rate: 0.9)
    family = @purchase.account.family

    [ same_currency, foreign_currency ].each do |inflow|
      assert_equal 1, family.transfer_match_candidates(
        inflow_transaction_id: inflow.transaction.id, outflow_transaction_id: @purchase.transaction.id
      ).size
    end

    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)

    [ same_currency, foreign_currency ].each do |inflow|
      assert_empty family.transfer_match_candidates(
        inflow_transaction_id: inflow.transaction.id, outflow_transaction_id: @purchase.transaction.id
      )
    end
  end

  test "a refund larger than the purchase retains the actual credit" do
    @credit.update!(amount: -1020)
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    assert_equal Money.new(-20, "USD"), @purchase.transaction.purchase_net_cost_money
  end

  test "manual refund classification is protected from provider enrichment" do
    @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    @credit.transaction.enrich_attribute(:kind, "standard", source: "plaid")
    assert @credit.transaction.reload.refund?
  end
end
