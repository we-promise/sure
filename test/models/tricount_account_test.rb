# frozen_string_literal: true

require "test_helper"
require_relative "../support/tricount_test_helper"

class TricountAccountTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @family = families(:empty)
    @item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @tricount_account = @item.tricount_accounts.new
    @tricount_account.upsert_from_tricount!(tricount_registry)
    @tricount_account.assign_member!(ME)
    @account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    @tricount_account.ensure_account_provider!(@account)
    TricountAccount::Processor.new(@tricount_account.reload).process
  end

  def payment_rows
    @account.entries.where(source: "tricount").where("external_id LIKE 'e1:paid%'").order(:external_id).map { |entry| [ entry.external_id, entry.amount, entry.name ] }
  end

  # Paid with two charges: a row per part, each matchable with one of them.
  test "splitting a payment replaces its row with one per part" do
    Account.any_instance.expects(:sync_later).once

    @tricount_account.split_payment!("e1", [ "60.00", " 40.00 ", "" ])

    assert_equal({ "e1" => [ "60.00", "40.00" ] }, @tricount_account.reload.paid_splits)
    assert_equal [
      [ "e1:paid:1", BigDecimal("-60"), "Dinner (you paid, part 1 of 2)" ],
      [ "e1:paid:2", BigDecimal("-40"), "Dinner (you paid, part 2 of 2)" ]
    ], payment_rows
    assert_equal BigDecimal("-20"), @account.reload.balance
  end

  # The row the user matched with a card charge goes, and its match with it:
  # the card charge is an ordinary transaction again, ready for a part.
  test "splitting removes the whole payment's row even when it was matched" do
    row = @account.entries.find_by!(external_id: "e1:paid")
    card = @family.accounts.create!(name: "Card", balance: 0, currency: "EUR", accountable: CreditCard.new)
    charge = card.entries.create!(name: "Restaurant", date: row.date, amount: 100, currency: "EUR", entryable: Transaction.new)
    Transfer.create!(inflow_transaction: row.entryable, outflow_transaction: charge.entryable, status: "confirmed")

    @tricount_account.split_payment!("e1", [ "60.00", "40.00" ])

    assert_not Entry.exists?(row.id)
    assert_nil charge.reload.entryable.transfer
    assert_equal [ "e1:paid:1", "e1:paid:2" ], payment_rows.map(&:first)
  end

  test "a split that doesn't add up is refused and changes nothing" do
    assert_raises(TricountAccount::InvalidPaymentSplit) { @tricount_account.split_payment!("e1", [ "60.00", "30.00" ]) }
    assert_raises(TricountAccount::InvalidPaymentSplit) { @tricount_account.split_payment!("e2", [ "20.00", "20.00" ]) }

    assert_equal({}, @tricount_account.reload.paid_splits)
    assert_equal [ "e1:paid" ], payment_rows.map(&:first)
  end

  test "undoing a split puts the payment back in one row" do
    @tricount_account.split_payment!("e1", [ "60.00", "40.00" ])

    @tricount_account.remove_payment_split!("e1")

    assert_equal({}, @tricount_account.reload.paid_splits)
    assert_equal [ [ "e1:paid", BigDecimal("-100"), "Dinner (you paid)" ] ], payment_rows
  end

  # Edited in Tricount, the payment no longer matches the parts: the next sync
  # forgets the split and writes the payment whole.
  test "a sync forgets a split whose payment changed in Tricount" do
    @tricount_account.split_payment!("e1", [ "60.00", "40.00" ])
    entries = tricount_entries
    entries[0] = tricount_entry(uuid: "e1", payer: ME, amount: "-120.00", allocations: { ME => "-30.00", SAM => "-30.00", KIM => "-60.00" }, description: "Dinner", category: "FOOD")

    @tricount_account.upsert_from_tricount!(tricount_registry(entries: entries))
    TricountAccount::Processor.new(@tricount_account.reload).process

    assert_equal({}, @tricount_account.paid_splits)
    assert_equal [ [ "e1:paid", BigDecimal("-120"), "Dinner (you paid)" ] ], payment_rows
  end

  test "following another member forgets the splits of payments they didn't make" do
    @tricount_account.split_payment!("e1", [ "60.00", "40.00" ])

    @tricount_account.assign_member!(SAM)

    assert_equal({}, @tricount_account.reload.paid_splits)
  end
end
