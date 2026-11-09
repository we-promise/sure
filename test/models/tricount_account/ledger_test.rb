# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class TricountAccount::LedgerTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @ledger = TricountAccount::Ledger.new(tricount_entries)
  end

  test "a member's balance is their allocations less what they paid, over active entries" do
    assert_equal BigDecimal("-20"), @ledger.balance_for(ME)
    assert_equal BigDecimal("60"), @ledger.balance_for(SAM)
    assert_equal BigDecimal("-40"), @ledger.balance_for(KIM)
  end

  test "the members' balances add up to zero" do
    assert_equal 0, [ ME, SAM, KIM ].sum { |member| @ledger.balance_for(member) }
  end

  test "a deleted entry counts for nothing" do
    assert_not_includes @ledger.active_entries.map(&:uuid), "e4"
  end

  test "what the member paid is a transfer leg and their share is spending" do
    legs = @ledger.legs_for(ME).index_by(&:external_id)

    assert_equal %w[e1:paid e1:share e2:share e3:share e5:paid e5:share], legs.keys.sort
    assert_equal [ BigDecimal("-100"), "funds_movement", nil ], legs["e1:paid"].to_h.values_at(:amount, :kind, :category)
    assert_equal [ BigDecimal("25"), "standard", "FOOD" ], legs["e1:share"].to_h.values_at(:amount, :kind, :category)
    assert_equal [ BigDecimal("10"), "standard", "TRANSPORT" ], legs["e2:share"].to_h.values_at(:amount, :kind, :category)
  end

  test "a settle-up is a transfer leg, not spending" do
    leg = @ledger.legs_for(ME).find { |candidate| candidate.external_id == "e3:share" }

    assert_equal [ BigDecimal("65"), "funds_movement", nil ], leg.to_h.values_at(:amount, :kind, :category)
  end

  test "money the member received for the group is a transfer leg out and their share is income" do
    legs = @ledger.legs_for(ME).index_by(&:external_id)

    assert_equal [ BigDecimal("30"), "funds_movement" ], legs["e5:paid"].to_h.values_at(:amount, :kind)
    assert_equal [ BigDecimal("-10"), "standard" ], legs["e5:share"].to_h.values_at(:amount, :kind)
  end

  # Sure's sign: positive is money out, so the account balance is minus the sum.
  test "the legs add up to the member's balance" do
    assert_equal(-@ledger.balance_for(ME), @ledger.legs_for(ME).sum(&:amount))
    assert_equal(-@ledger.balance_for(SAM), @ledger.legs_for(SAM).sum(&:amount))
  end

  test "a member with no part in an entry gets no leg for it" do
    assert_empty @ledger.legs_for(KIM).select { |leg| leg.entry.uuid.in?(%w[e2 e3]) }
  end

  test "an uncategorised entry has no category and a custom label wins over Tricount's category" do
    entries = [
      tricount_entry(uuid: "u1", payer: ME, amount: "-10", allocations: { ME => "-10" }, category: "UNCATEGORIZED"),
      tricount_entry(uuid: "u2", payer: ME, amount: "-10", allocations: { ME => "-10" }, category: "GROCERIES").tap { |e| e["RegistryEntry"]["category_custom"] = "Market" }
    ]

    categories = TricountAccount::Ledger.new(entries).entries.to_h { |entry| [ entry.uuid, entry.category ] }

    assert_equal({ "u1" => nil, "u2" => "Market" }, categories)
  end

  # 10.00 split three ways is stored as 3.33, 3.33 and 3.34; Tricount's own
  # balance comes from the exact thirds.
  test "the balance follows the exact ratio shares and a rounding leg makes up the stored cents" do
    entries = 3.times.map do |i|
      tricount_entry(uuid: "r#{i}", payer: ME, amount: "-10.00", allocations: { ME => "-3.33", SAM => "-3.33", KIM => "-3.34" }).tap do |entry|
        entry["RegistryEntry"]["allocations"].each { |allocation| allocation["type"] = "RATIO"; allocation["share_ratio"] = 1 }
      end
    end
    ledger = TricountAccount::Ledger.new(entries)

    assert_equal BigDecimal("20.01"), ledger.stored_balance_for(ME)
    assert_equal BigDecimal("20.00"), ledger.balance_for(ME)
    rounding = ledger.legs_for(ME).find { |leg| leg.external_id == "rounding" }
    assert_equal [ BigDecimal("0.01"), "funds_movement" ], [ rounding.amount, rounding.kind ]
    assert_equal(-ledger.balance_for(ME), ledger.legs_for(ME).sum(&:amount))
  end

  # Stored shares of 0.00 each can still add up, exactly, to a cent: the
  # rounding leg is then the member's only transaction.
  test "a rounding leg even when the member's stored shares are all zero" do
    entries = 3.times.map do |i|
      tricount_entry(uuid: "z#{i}", payer: SAM, amount: "-1.00", allocations: { ME => "-0.00", SAM => "-1.00" }).tap do |entry|
        entry["RegistryEntry"]["allocations"].each { |allocation| allocation["type"] = "RATIO" }
        entry["RegistryEntry"]["allocations"][0]["share_ratio"] = 1
        entry["RegistryEntry"]["allocations"][1]["share_ratio"] = 299
      end
    end
    ledger = TricountAccount::Ledger.new(entries)

    assert_equal BigDecimal("0"), ledger.stored_balance_for(ME)
    assert_equal BigDecimal("-0.01"), ledger.balance_for(ME)
    assert_equal [ "rounding" ], ledger.legs_for(ME).map(&:external_id)
    assert_equal(-ledger.balance_for(ME), ledger.legs_for(ME).sum(&:amount))
  end

  test "no rounding leg when the stored shares add up exactly" do
    assert_not @ledger.legs_for(ME).any? { |leg| leg.external_id == "rounding" }
  end

  test "members are read from wrapped memberships" do
    members = TricountAccount::Ledger.members_from(tricount_registry)

    assert_equal [ [ ME, "Alex" ], [ SAM, "Sam" ], [ KIM, "Kim" ] ], members.map { |member| [ member.uuid, member.name ] }
  end
  # A payment split into parts gives a leg per part, so each pairs with its own
  # charge; the legs still add up to the balance.
  test "a split payment gives one leg per part" do
    legs = @ledger.legs_for(ME, paid_splits: { "e1" => [ "60.00", "40.00" ] })

    paid = legs.select { |leg| leg.external_id.start_with?("e1:paid") }
    assert_equal [ [ "e1:paid:1", BigDecimal("-60") ], [ "e1:paid:2", BigDecimal("-40") ] ], paid.map { |leg| [ leg.external_id, leg.amount ] }
    assert paid.all? { |leg| leg.kind == "funds_movement" }
    assert_equal(-@ledger.balance_for(ME), legs.sum(&:amount))
  end

  test "a split of money received for the group keeps its sign" do
    legs = @ledger.legs_for(ME, paid_splits: { "e5" => [ "20.00", "10.00" ] })

    assert_equal [ BigDecimal("20"), BigDecimal("10") ], legs.select { |leg| leg.external_id.start_with?("e5:paid:") }.map(&:amount)
    assert_equal(-@ledger.balance_for(ME), legs.sum(&:amount))
  end

  test "a split that doesn't add up, has one part, a part at zero or too many decimals leaves the payment whole" do
    [ [ "60.00", "30.00" ], [ "100.00" ], [ "100.00", "0" ], [ "60.005", "39.995" ], [ "sixty", "40" ], "60,40" ].each do |parts|
      paid = @ledger.legs_for(ME, paid_splits: { "e1" => parts }).select { |leg| leg.external_id.start_with?("e1:paid") }

      assert_equal [ "e1:paid" ], paid.map(&:external_id), "parts #{parts.inspect} were applied"
    end
  end

  test "only splits of entries the member paid still apply" do
    splits = { "e1" => [ "60.00", "40.00" ], "e2" => [ "20.00", "20.00" ], "e4" => [ "250.00", "250.00" ], "gone" => [ "1.00", "1.00" ], "e5" => [ "29.00", "2.00" ] }

    assert_equal({ "e1" => [ "60.00", "40.00" ] }, @ledger.applicable_paid_splits(ME, splits))
    assert_equal({ "e2" => [ "20.00", "20.00" ] }, @ledger.applicable_paid_splits(SAM, splits))
  end
end
