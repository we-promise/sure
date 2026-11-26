require "test_helper"

class PurchaseTest < ActiveSupport::TestCase
  test "an unlinked purchase is visible only to its user" do
    purchase = purchases(:allegro_awaiting)

    assert_includes Purchase.visible_to(users(:family_admin)), purchase
    refute_includes Purchase.visible_to(users(:family_member)), purchase
  end

  test "a linked purchase is visible to users who can access the transaction's account" do
    purchase = purchases(:allegro_matched)

    assert_includes Purchase.visible_to(users(:family_member)), purchase
  end

  test "to_match lists purchases still waiting for a payment" do
    assert_includes Purchase.to_match, purchases(:allegro_awaiting)
    refute_includes Purchase.to_match, purchases(:allegro_matched)
  end

  test "deleting the linked transaction reopens an email purchase" do
    purchase = purchases(:allegro_matched)

    purchase.linked_transaction.entry.destroy!

    purchase.reload
    assert_equal "awaiting_payment", purchase.status
    assert_nil purchase.transaction_id
    assert_nil purchase.matched_at
  end

  test "deleting the linked transaction leaves a receipt purchase unmatched" do
    purchase = purchases(:allegro_matched)
    purchase.update!(source: :receipt)

    purchase.linked_transaction.entry.destroy!

    assert_equal "unmatched", purchase.reload.status
  end

  test "match window is 14 days for cash on delivery and 3 otherwise" do
    assert_equal 14, Purchase.new(payment_method: "cash_on_delivery").match_window_days
    assert_equal 3, Purchase.new(payment_method: "card").match_window_days
  end

  test "flag! appends a review reason without changing the status" do
    purchase = purchases(:allegro_awaiting)

    purchase.flag!(:items_mismatch, expected: "10.00")

    assert_equal "awaiting_payment", purchase.reload.status
    assert_equal [ { "reason" => "items_mismatch", "expected" => "10.00" } ], purchase.review_reasons
  end

  test "items are ordered by position" do
    purchase = purchases(:allegro_awaiting)
    purchase.items.create!(name: "B", amount: 1, position: 1)
    purchase.items.create!(name: "A", amount: 1, position: 0)

    assert_equal %w[A B], purchase.items.reload.map(&:name)
  end

  test "destroying the user destroys their purchases" do
    purchase = Purchase.create!(family: families(:dylan_family), user: users(:family_member), source: :email)

    users(:family_member).destroy!

    assert_not Purchase.exists?(purchase.id)
  end
end
