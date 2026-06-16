require "test_helper"

class Family::CardChangeMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Distinctive amount to avoid colliding with existing fixtures
  AMOUNT = 412

  setup do
    @family = families(:dylan_family)
    @account_a = accounts(:depository)  # original purchase + reimbursement
    @account_b = accounts(:credit_card) # new-card charge
  end

  test "detects a card-change reimbursement trio" do
    trio = build_trio
    assert_includes candidate_tuples, trio
  end

  test "does not detect when the pair was dismissed" do
    trio = build_trio
    RejectedTransfer.create!(inflow_transaction_id: trio[:inflow], outflow_transaction_id: trio[:outflow])

    assert_not_includes candidate_tuples, trio
  end

  test "does not detect when the pair is already a transfer" do
    trio = build_trio
    Transfer.create!(
      inflow_transaction_id: trio[:inflow],
      outflow_transaction_id: trio[:outflow],
      status: "confirmed",
      kind: "card_change"
    )

    assert_not_includes candidate_tuples, trio
  end

  test "does not detect without an originating purchase" do
    trio = build_trio(skip_original: true)
    assert_not_includes candidate_tuples, trio
  end

  test "does not detect when the span exceeds the purchase window" do
    trio = build_trio(purchase_days_ago: 250)
    assert_not_includes candidate_tuples, trio
  end

  private
    def build_trio(purchase_days_ago: 90, skip_original: false)
      original = unless skip_original
        create_transaction(account: @account_a, amount: AMOUNT, date: purchase_days_ago.days.ago.to_date, kind: "standard")
      end
      outflow = create_transaction(account: @account_b, amount: AMOUNT, date: 30.days.ago.to_date, kind: "standard")
      inflow = create_transaction(account: @account_a, amount: -AMOUNT, date: 25.days.ago.to_date, kind: "standard")

      {
        original: original&.entryable_id,
        outflow: outflow.entryable_id,
        inflow: inflow.entryable_id
      }
    end

    def candidate_tuples
      @family.card_change_reimbursement_candidates.map do |c|
        { original: c.original_transaction_id, outflow: c.outflow_transaction_id, inflow: c.inflow_transaction_id }
      end
    end
end
