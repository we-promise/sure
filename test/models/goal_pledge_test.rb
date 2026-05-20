require "test_helper"

class GoalPledgeTest < ActiveSupport::TestCase
  setup do
    @goal = goals(:vacation_italy)
    @account = accounts(:depository)
    @pledge = goal_pledges(:open_transfer)
  end

  test "valid fixture pledge saves" do
    assert @pledge.valid?
  end

  test "amount must be positive" do
    @pledge.amount = 0
    assert_not @pledge.valid?
  end

  test "account must be linked to goal" do
    other_account = accounts(:investment)
    pledge = @goal.goal_pledges.new(account: other_account, amount: 50, currency: "USD")
    assert_not pledge.valid?
    assert_includes pledge.errors[:account], "Pick one of the goal's linked accounts."
  end

  test "currency must match goal currency" do
    @pledge.currency = "EUR"
    assert_not @pledge.valid?
    assert_includes @pledge.errors[:currency], "Pledge currency must match the goal currency."
  end

  test "defaults populate on create" do
    pledge = @goal.goal_pledges.new(account: @account, amount: 50)
    pledge.valid?
    assert_equal "open", pledge.status
    assert_equal "transfer", pledge.kind
    assert_not_nil pledge.expires_at
    assert pledge.expires_at > Time.current
    assert_equal @goal.currency, pledge.currency
  end

  test "matches? returns true within tolerances" do
    entry = build_entry(account: @account, amount: -200.25, date: @pledge.created_at.to_date + 1.day)
    assert @pledge.matches?(entry)
  end

  test "matches? returns false outside date window" do
    entry = build_entry(account: @account, amount: -200, date: @pledge.created_at.to_date + 10.days)
    assert_not @pledge.matches?(entry)
  end

  test "matches? returns false outside amount tolerance" do
    entry = build_entry(account: @account, amount: -250, date: @pledge.created_at.to_date)
    assert_not @pledge.matches?(entry)
  end

  test "matches? returns true within ratio tolerance" do
    entry = build_entry(account: @account, amount: -201.99, date: @pledge.created_at.to_date)
    assert @pledge.matches?(entry)
  end

  test "matches? returns false on wrong account" do
    other_account = accounts(:connected)
    entry = build_entry(account: other_account, amount: -200, date: @pledge.created_at.to_date)
    assert_not @pledge.matches?(entry)
  end

  test "matches? rejects outflows of the same magnitude on transfer pledges" do
    # Sure convention: outflow > 0, inflow < 0. A +$200 purchase must not
    # satisfy a $200 transfer pledge after the .abs amount-tolerance step.
    entry = build_entry(account: @account, amount: 200, date: @pledge.created_at.to_date)
    assert_not @pledge.matches?(entry)
  end

  test "matches? returns false on already-matched pledge" do
    matched = goal_pledges(:matched_transfer)
    entry = build_entry(account: matched.account, amount: -matched.amount.to_d, date: matched.created_at.to_date)
    assert_not matched.matches?(entry)
  end

  test "extend! pushes expires_at forward" do
    before = @pledge.expires_at
    @pledge.extend!
    assert @pledge.expires_at > before + 6.days
  end

  test "matches? widens upper bound to expires_at after extend!" do
    # Day 8 — past the default 5-day creation-anchored window but inside the
    # extended expiry window. Without the widening this would be a regression
    # of B7 (extend doesn't actually buy match runway).
    @pledge.extend!
    far_date = @pledge.created_at.to_date + 8.days
    assert far_date <= @pledge.expires_at.to_date
    entry = build_entry(account: @account, amount: -200, date: far_date)
    assert @pledge.matches?(entry)
  end

  test "matches? rejects entries past extended expires_at" do
    @pledge.extend!
    far_date = @pledge.expires_at.to_date + 1.day
    entry = build_entry(account: @account, amount: -200, date: far_date)
    assert_not @pledge.matches?(entry)
  end

  test "duplicate open pledge for same goal+account+amount is rejected on create" do
    dup = @goal.goal_pledges.new(account: @account, amount: @pledge.amount, currency: @goal.currency)
    assert_not dup.valid?
    assert dup.errors[:base].any? { |m| m.include?("open pledge") }
  end

  test "duplicate validation does not block different amounts" do
    dup = @goal.goal_pledges.new(account: @account, amount: @pledge.amount.to_d + 1, currency: @goal.currency)
    assert dup.valid?, dup.errors.full_messages.to_sentence
  end

  test "extend! raises for non-open pledge" do
    pledge = goal_pledges(:matched_transfer)
    assert_raises(GoalPledge::NotOpenError) { pledge.extend! }
  end

  test "cancel! transitions open to cancelled" do
    @pledge.cancel!
    assert @pledge.status_cancelled?
  end

  test "expire! transitions open to expired" do
    @pledge.expire!
    assert @pledge.status_expired?
  end

  test "days_left counts down" do
    @pledge.expires_at = 3.days.from_now
    assert_includes 2..3, @pledge.days_left
  end

  test "days_left returns 0 for non-open" do
    pledge = goal_pledges(:matched_transfer)
    assert_equal 0, pledge.days_left
  end

  test "amount cannot be negative" do
    @pledge.amount = -5
    assert_not @pledge.valid?
    assert_includes @pledge.errors[:amount], "must be greater than 0"
  end

  test "expire! is a no-op on an already-expired pledge" do
    @pledge.expire!
    expired_at = @pledge.updated_at
    travel 1.second do
      @pledge.expire!
      assert_equal expired_at.to_i, @pledge.updated_at.to_i, "second expire! should not touch the row"
    end
    assert @pledge.status_expired?
  end

  test "cancel! raises on non-open pledge" do
    pledge = goal_pledges(:matched_transfer)
    assert_raises(GoalPledge::NotOpenError) { pledge.cancel! }
  end

  private
    def build_entry(account:, amount:, date:)
      OpenStruct.new(account_id: account.id, amount: BigDecimal(amount.to_s), date: date.to_date)
    end
end
