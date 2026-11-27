require "test_helper"

# Mode-specific value rules (the same shape the DB check constraint
# chk_plan_allocations_value_mode enforces), same-family references, and the
# required-mode amount resolution.
class PlanAllocationTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @account = accounts(:depository)
    @other_family = families(:empty)
    @bill = recurring_transactions(:netflix_subscription)
  end

  def build(mode:, value_cents: nil, value_percent: nil, name: "Netflix", kind: "bill",
            recurring_transaction: nil, family: @family, account: @account, category: nil)
    PlanAllocation.new(
      family: family,
      account: account,
      name: name,
      kind: kind,
      mode: mode,
      value_cents: value_cents,
      value_percent: value_percent,
      recurring_transaction: recurring_transaction,
      category: category
    )
  end

  test "required: value_cents OR a linked recurring transaction" do
    assert_not build(mode: "required").valid?
    assert build(mode: "required", value_cents: 1599).valid?
    assert build(mode: "required", recurring_transaction: @bill).valid?
    assert build(mode: "required", value_cents: 1599, recurring_transaction: @bill).valid?
    # The percent field is not allowed on required rows.
    assert_not build(mode: "required", value_cents: 1599, value_percent: 0.5).valid?
  end

  test "specific: a positive per-paycheck value_cents" do
    assert_not build(mode: "specific").valid?
    assert_not build(mode: "specific", value_cents: 0).valid?
    assert_not build(mode: "specific", value_cents: -100).valid?
    assert build(mode: "specific", value_cents: 1599).valid?
    assert_not build(mode: "specific", value_cents: 1599, value_percent: 0.5).valid?
  end

  test "percent: a fraction in (0, 1]" do
    assert_not build(mode: "percent", value_percent: 0).valid?
    assert_not build(mode: "percent", value_percent: 1.5).valid?
    assert build(mode: "percent", value_percent: 0.5).valid?
    assert build(mode: "percent", value_percent: 1).valid?
    assert_not build(mode: "percent", value_cents: 100).valid?
  end

  test "leftover: no stored value at all" do
    assert build(mode: "leftover").valid?
    assert_not build(mode: "leftover", value_cents: 100).valid?
    assert_not build(mode: "leftover", value_percent: 0.5).valid?
  end

  # Round 10 issue 4: a savings bucket is a MONTHLY figure (mode forced
  # "required" by the controller; the dialog hides the detected-bill link,
  # so the bucket always needs its typed value).
  test "required savings bucket: the monthly value is required" do
    bucket = build(mode: "required", kind: "savings", name: "Pet Safety Fund")
    assert_not bucket.valid?
    assert_equal [ "is required for a savings bucket" ], bucket.errors[:value_cents]
    assert build(mode: "required", kind: "savings", name: "Pet Safety Fund",
      value_cents: 25_000).valid?
    # A linked recurring transaction does NOT satisfy a bucket (no link
    # control exists for kind "savings").
    assert_not build(mode: "required", kind: "savings", name: "Pet Safety Fund",
      recurring_transaction: @bill).valid?
  end

  test "name is required and cadence must be a known cadence" do
    allocation = build(mode: "specific", value_cents: 100)
    allocation.name = nil
    assert_not allocation.valid?
    assert allocation.errors[:name].any?

    assert_not build(mode: "specific", value_cents: 100, name: "X").tap { |a| a.cadence = "fortnightly" }.valid?
    assert build(mode: "specific", value_cents: 100, name: "X").tap { |a| a.cadence = "biweekly" }.valid?
  end

  test "the source bank and the recurring transaction must be of the family" do
    other = build(mode: "specific", value_cents: 100, family: @other_family)
    assert_not other.valid?
    assert other.errors[:account].any?

    linked = build(mode: "required", recurring_transaction: @bill, family: @other_family)
    assert_not linked.valid?
    assert linked.errors[:recurring_transaction].any?
    # Same family stays clean.
    assert build(mode: "specific", value_cents: 100).valid?
  end

  test "resolved_monthly_amount: explicit value beats the linked RT" do
    linked = PlanAllocation.new(family: @family, account: @account, name: "Netflix", kind: "bill", mode: "required", recurring_transaction: @bill)
    monthly = @bill.monthly_equivalent_amount.amount * 100
    assert_equal monthly, linked.resolved_monthly_amount

    explicit = PlanAllocation.new(family: @family, account: @account, name: "Netflix", kind: "bill", mode: "required", value_cents: 2000, recurring_transaction: @bill)
    assert_equal 2000, explicit.resolved_monthly_amount
  end

  # dependent: :nullify detaches the allocation when the linked series is
  # destroyed. A required-mode allocation whose only amount source is the
  # series would violate chk_plan_allocations_value_mode once detached
  # (value_cents NULL and recurring_transaction_id NULL), so the series
  # persists the explicit monthly amount on those rows before detaching.
  test "destroying the linked series persists the monthly amount on a required allocation" do
    allocation = PlanAllocation.create!(
      family: @family, account: @account, name: "Netflix", kind: "bill",
      mode: "required", recurring_transaction: @bill
    )
    assert_nil allocation.value_cents

    expected = (@bill.monthly_equivalent_amount.amount * 100).round

    assert @bill.destroy

    allocation.reload
    assert_equal expected, allocation.value_cents
    assert_nil allocation.recurring_transaction_id
    assert allocation.valid?
  end

  test "kind and mode enums are the frozen spec sets" do
    assert_equal %w[bill debt savings fun_money], PlanAllocation.kinds.keys
    assert_equal %w[required specific percent leftover], PlanAllocation.modes.keys

    fun = build(mode: "specific", value_cents: 100)
    fun.kind = "fun_money"
    assert fun.valid?
  end

  # Round 16 (owner note 2): the optional Sure category link (the diagram's
  # band color). Nil is the default (no color); a category from another
  # family is rejected like the other cross-family references.
  test "category is optional and must belong to the allocation's family" do
    category = @family.categories.create!(name: "Groceries", color: "#11AA22")
    foreign = @other_family.categories.create!(name: "Foreign Groceries", color: "#AA1122")

    assert build(mode: "specific", value_cents: 100).valid?
    assert build(mode: "specific", value_cents: 100, category: category).valid?

    foreign_alloc = build(mode: "specific", value_cents: 100, category: foreign)
    assert_not foreign_alloc.valid?
    assert foreign_alloc.errors[:category].any?
  end
end
