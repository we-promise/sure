require "test_helper"

class Purchase::FromReceiptScanTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @scan = receipt_scans(:processing)
    @entry = create_transaction(account: @scan.account, amount: 50, date: Date.current - 1.day, name: "Corner Grocer")
    @scan.update!(linked_transaction: @entry.entryable, status: :completed)
    @extraction = build_receipt_extraction(payment_method: "cash").to_h.as_json
  end

  test "syncing twice updates the same purchase" do
    first = Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction, ai_metadata: { "model" => "a" })
    second = Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction.merge("merchant" => "Renamed"), ai_metadata: { "model" => "b" })

    assert_equal first.id, second.id
    assert_equal "Renamed", second.merchant
    assert_equal 2, second.items.count
    assert_equal "b", second.ai_metadata["model"]
  end

  test "a scan whose uploader was removed gets no purchase" do
    @scan.update!(user: nil)

    assert_no_difference -> { Purchase.count } do
      assert_nil Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction, ai_metadata: {})
    end
  end

  test "line discounts reduce the item amount and cash stays cash" do
    @extraction["line_items"] = [ { "name" => "Cheese", "quantity" => "2", "amount" => "30.00", "discount" => "5.00", "category_name" => "Food & Drink" } ]

    purchase = Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction, ai_metadata: {})

    item = purchase.items.first
    assert_equal BigDecimal("25.00"), item.amount
    assert_equal BigDecimal("2"), item.quantity
    assert_equal categories(:food_and_drink), item.category
    assert_equal "cash", purchase.payment_method
  end

  test "a scan without a transaction gives an unmatched purchase" do
    @scan.update!(linked_transaction: nil)

    purchase = Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction, ai_metadata: {})

    assert_equal "unmatched", purchase.status
  end

  test "an email purchase that claims the transaction meanwhile keeps it" do
    email_purchase = purchases(:allegro_awaiting)
    email_purchase.update!(linked_transaction: @entry.entryable, status: :matched)
    Purchase::FromReceiptScan.any_instance.stubs(:transaction_owner).returns(nil).then.returns(email_purchase)

    purchase = Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction, ai_metadata: {})

    assert_equal "unmatched", purchase.status
    assert_nil purchase.transaction_id
    assert_equal @entry.entryable, email_purchase.reload.linked_transaction
  end

  test "a scan whose uploader is in another family gets no purchase" do
    @scan.user.update_columns(family_id: families(:empty).id)

    assert_no_difference -> { Purchase.count } do
      assert_nil Purchase::FromReceiptScan.sync!(@scan.reload, extraction_hash: @extraction, ai_metadata: {})
    end
  end

  test "a transaction that already has an email purchase keeps it; the receipt purchase stays unlinked" do
    email_purchase = purchases(:allegro_awaiting)
    email_purchase.update!(linked_transaction: @entry.entryable, status: :matched)

    purchase = Purchase::FromReceiptScan.sync!(@scan, extraction_hash: @extraction, ai_metadata: {})

    assert_equal "unmatched", purchase.status
    assert_nil purchase.transaction_id
    assert_equal({ "reason" => "already_linked", "purchase_id" => email_purchase.id }, purchase.review_reasons.last)
    assert_equal @entry.entryable, email_purchase.reload.linked_transaction
  end
end
