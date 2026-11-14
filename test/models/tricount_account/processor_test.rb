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
end
