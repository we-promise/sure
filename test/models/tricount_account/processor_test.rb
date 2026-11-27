# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class TricountAccount::ProcessorTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @family = families(:empty)
    @item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @tricount_account = @item.tricount_accounts.new
    @tricount_account.upsert_from_tricount!(tricount_registry)
    @tricount_account.assign_member!(ME)
    @account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    @tricount_account.ensure_account_provider!(@account)
  end

  def process!
    TricountAccount::Processor.new(@tricount_account.reload).process
  end

  def tricount_entries_by_leg
    @account.entries.where(source: "tricount").index_by(&:external_id)
  end

  # The account's own sync runs once every leg is imported (scheduled by the
  # item's sync), not halfway through from the balance update.
  test "processing schedules no account sync of its own" do
    Account.any_instance.expects(:sync_later).never

    process!

    assert_equal BigDecimal("-20"), @account.reload.balance
  end

  # Switching the account's currency would reinterpret its history.
  test "a tricount whose currency changed leaves its account alone and reports it" do
    process!
    entries = @account.entries.count
    @tricount_account.update_columns(currency: "CHF")

    error = assert_raises(TricountAccount::Processor::CurrencyChangedError) { process! }

    assert_includes error.message, "CHF"
    assert_equal [ "EUR", BigDecimal("-20"), entries ], [ @account.reload.currency, @account.balance, @account.entries.count ]
  end

  # The balance and its anchor go together; a failed anchor fails the
  # account's processing rather than leaving a balance with no anchor.
  test "a balance anchor that can't be written fails processing and keeps the old balance" do
    Account.any_instance.stubs(:set_current_balance).returns(Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "anchor rotation failed"))

    error = assert_raises(TricountAccount::Processor::AnchorError) { process! }

    assert_includes error.message, "anchor rotation failed"
    assert_equal BigDecimal("0"), @account.reload.balance
    assert_empty @account.entries.where(source: "tricount")
  end

  test "the account balance is the member's position" do
    process!

    assert_equal BigDecimal("-20"), @account.reload.balance
  end

  test "each leg becomes a transaction, a paid leg as a transfer and a share as spending" do
    process!
    entries = tricount_entries_by_leg

    assert_equal %w[e1:paid e1:share e2:share e3:share e5:paid e5:share], entries.keys.sort
    assert_equal [ BigDecimal("-100"), "funds_movement" ], [ entries["e1:paid"].amount, entries["e1:paid"].entryable.kind ]
    assert_equal I18n.t("tricount_items.transactions.paid_name", description: "Dinner"), entries["e1:paid"].name
    assert_equal [ BigDecimal("30"), I18n.t("tricount_items.transactions.received_name", description: "Group refund") ], [ entries["e5:paid"].amount, entries["e5:paid"].name ]
    assert_equal [ BigDecimal("25"), "standard", "Dinner" ], [ entries["e1:share"].amount, entries["e1:share"].entryable.kind, entries["e1:share"].name ]
    assert_equal "funds_movement", entries["e3:share"].entryable.kind
    assert_equal Date.new(2026, 10, 2), entries["e2:share"].date
  end

  test "a share takes the family's matching category" do
    dining = @family.categories.create!(name: "Food & Drink", color: "#000000")

    process!

    assert_equal dining, tricount_entries_by_leg["e1:share"].entryable.category
    assert_nil tricount_entries_by_leg["e2:share"].entryable.category, "no Transportation category to match"
  end

  # The "tricount" metadata is a snapshot of the entry: a field Tricount stops
  # sending goes, on a transaction the user edited too.
  test "a category removed in Tricount leaves the transaction's metadata" do
    process!
    assert_equal "FOOD", tricount_entries_by_leg["e1:share"].entryable.extra.dig("tricount", "category")
    tricount_entries_by_leg["e2:share"].update!(user_modified: true)

    uncategorised = tricount_entries.map { |entry| entry.deep_merge("RegistryEntry" => { "category" => nil }) }
    @tricount_account.upsert_from_tricount!(tricount_registry(entries: uncategorised))
    process!

    entries = tricount_entries_by_leg
    assert_not entries["e1:share"].entryable.extra["tricount"].key?("category")
    assert_not entries["e2:share"].entryable.extra["tricount"].key?("category"), "an edited transaction still gets the current metadata"
    assert_equal "Sam", entries["e2:share"].entryable.extra.dig("tricount", "paid_by")
  end

  test "an entry deleted in Tricount loses its transactions" do
    process!
    remaining = tricount_entries.reject { |entry| entry.dig("RegistryEntry", "uuid") == "e2" }
    @tricount_account.upsert_from_tricount!(tricount_registry(entries: remaining))

    process!

    assert_not tricount_entries_by_leg.key?("e2:share")
    assert_equal BigDecimal("-10"), @account.reload.balance
  end

  test "a transaction the user edited stays when its entry is deleted in Tricount" do
    process!
    tricount_entries_by_leg["e2:share"].update!(user_modified: true)
    remaining = tricount_entries.reject { |entry| entry.dig("RegistryEntry", "uuid") == "e2" }
    @tricount_account.upsert_from_tricount!(tricount_registry(entries: remaining))

    process!

    assert tricount_entries_by_leg.key?("e2:share")
  end

  test "following another member replaces the transactions with theirs" do
    process!
    @tricount_account.assign_member!(SAM)

    process!

    assert_equal %w[e1:share e2:paid e2:share e3:paid e5:share], tricount_entries_by_leg.keys.sort
    assert_equal BigDecimal("60"), @account.reload.balance
  end

  test "a paid leg pairs with the card payment it came from" do
    card = @family.accounts.create!(name: "Card", balance: 0, currency: "EUR", accountable: Depository.new)
    card.entries.create!(name: "Restaurant", amount: 100, currency: "EUR", date: Date.new(2026, 10, 1), entryable: Transaction.new)

    process!
    candidates = @family.transfer_match_candidates(account_id: @account.id)

    assert candidates.any? { |match| match.inflow_transaction_id == tricount_entries_by_leg["e1:paid"].entryable_id }
  end

  test "an account whose member left the tricount loses their transactions" do
    process!
    registry = tricount_registry
    registry["memberships"].reject! { |membership| membership.dig("RegistryMembershipNonUser", "uuid") == ME }
    @tricount_account.upsert_from_tricount!(registry)

    process!

    assert_nil @tricount_account.reload.member_uuid
    assert_empty tricount_entries_by_leg
    assert_equal BigDecimal("0"), @account.reload.balance
  end

  # The notes record what the entry was in Tricount: its category and amount.
  test "a transaction's notes give the Tricount category and amount" do
    process!

    entries = tricount_entries_by_leg
    assert_equal "Tricount category: Food\nAmount: #{Money.new(25, "EUR").format} (EUR)", entries["e1:share"].notes
    assert_equal "Tricount category: Food\nAmount: #{Money.new(100, "EUR").format} (EUR)", entries["e1:paid"].notes
    assert_equal "Amount: #{Money.new(65, "EUR").format} (EUR)", entries["e3:share"].notes, "an uncategorised settle-up has no category line"
    assert_nil entries["rounding"]&.notes
  end

  # Tricount converts an expense entered in another currency into the
  # tricount's, at the rate it records; the transactions use the converted
  # amount, so the account still adds up to the balance Tricount shows, and
  # the notes keep what was entered.
  test "an expense entered in another currency imports converted and notes the rate" do
    yen = tricount_entry(uuid: "e6", payer: ME, amount: "-20.40", allocations: { ME => "-10.20", SAM => "-10.20" }, description: "Ramen", category: "FOOD_AND_DRINK",
                         date: "2026-10-07 20:00:00.000000", local: { currency: "JPY", rate: "0.0068", amount: "-3000", allocations: { ME => "-1500", SAM => "-1500" } })
    @tricount_account.upsert_from_tricount!(tricount_registry(entries: tricount_entries + [ yen ]))
    process!

    share = tricount_entries_by_leg["e6:share"]
    paid = tricount_entries_by_leg["e6:paid"]
    assert_equal [ BigDecimal("10.20"), "EUR" ], [ share.amount, share.currency ]
    assert_equal [ BigDecimal("-20.40"), "EUR" ], [ paid.amount, paid.currency ]
    assert_equal BigDecimal("-9.80"), @account.reload.balance, "-20 before, plus the 10.20 Sam owes for the ramen"
    assert_equal [
      "Tricount category: Food and drink",
      "Entered: #{Money.new(1500, "JPY").format} (JPY)",
      "Exchange rate: 1 JPY = 0.0068 EUR",
      "Converted: #{Money.new(BigDecimal("10.20"), "EUR").format} (EUR)"
    ].join("\n"), share.notes
    assert_includes paid.notes, "Entered: #{Money.new(3000, "JPY").format} (JPY)"
    assert_equal "JPY", share.entryable.extra.dig("tricount", "entered_currency")
  end

  test "each part of a split payment notes the whole payment as entered" do
    yen = tricount_entry(uuid: "e6", payer: ME, amount: "-20.40", allocations: { ME => "-10.20", SAM => "-10.20" }, description: "Ramen",
                         date: "2026-10-07 20:00:00.000000", local: { currency: "JPY", rate: "0.0068", amount: "-3000", allocations: { ME => "-1500", SAM => "-1500" } })
    @tricount_account.upsert_from_tricount!(tricount_registry(entries: tricount_entries + [ yen ]))
    @tricount_account.update!(paid_splits: { "e6" => [ "15.40", "5.00" ] })
    process!

    part = tricount_entries_by_leg["e6:paid:1"]
    assert_includes part.notes, "Entered: #{Money.new(3000, "JPY").format} (JPY, the whole payment)"
    assert_includes part.notes, "Converted: #{Money.new(BigDecimal("15.40"), "EUR").format} (EUR)"
  end

  # Without a usable rate there is no conversion to describe: the notes give
  # the amount the transaction was imported at.
  test "an entry without a usable exchange rate notes just its amount" do
    odd = tricount_entry(uuid: "e6", payer: SAM, amount: "-20.40", allocations: { ME => "-20.40" }, description: "Odd",
                         date: "2026-10-07 20:00:00.000000", local: { currency: "JPY", rate: "", amount: "-3000", allocations: { ME => "-3000" } })
    @tricount_account.upsert_from_tricount!(tricount_registry(entries: tricount_entries + [ odd ]))
    process!

    assert_equal "Amount: #{Money.new(BigDecimal("20.40"), "EUR").format} (EUR)", tricount_entries_by_leg["e6:share"].notes
  end

  test "notes the user edited stay theirs on the next sync" do
    process!
    entry = tricount_entries_by_leg["e1:share"]
    entry.update!(notes: "Birthday dinner")
    entry.lock_saved_attributes!

    process!

    assert_equal "Birthday dinner", entry.reload.notes
  end
end
