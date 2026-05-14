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

  test "extend! raises for non-open pledge" do
    pledge = goal_pledges(:matched_transfer)
    assert_raises(ActiveRecord::RecordInvalid) { pledge.extend! }
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

  private
    def build_entry(account:, amount:, date:)
      OpenStruct.new(account_id: account.id, amount: BigDecimal(amount.to_s), date: date.to_date)
    end
end
