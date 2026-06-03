require "test_helper"

class EnvelopeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @category = Category.create!(name: "Holidays test", family: @family, color: "#4da568", lucide_icon: "plane")
  end

  # Builds an envelope anchored to a known start month so the
  # contribution-accrual maths are deterministic.
  def build_envelope(months_ago: 0, **attrs)
    @family.envelopes.create!({
      name: "Test envelope",
      category: @category,
      monthly_contribution: 100,
      currency: "USD",
      starts_on: months_ago.months.ago.to_date.beginning_of_month
    }.merge(attrs))
  end

  # --- Validations ---

  test "valid fixture envelope saves" do
    assert envelopes(:holidays).valid?
  end

  test "name is required" do
    envelope = @family.envelopes.new(monthly_contribution: 10, currency: "USD", starts_on: Date.current)
    assert_not envelope.valid?
    assert_includes envelope.errors[:name], "can't be blank"
  end

  test "monthly_contribution cannot be negative" do
    envelope = build_envelope
    envelope.monthly_contribution = -1
    assert_not envelope.valid?
  end

  test "monthly_contribution of zero is allowed" do
    assert build_envelope(monthly_contribution: 0).valid?
  end

  test "target_amount must be positive when present" do
    envelope = build_envelope
    envelope.target_amount = 0
    assert_not envelope.valid?
  end

  test "a category can back only one envelope" do
    build_envelope
    dup = @family.envelopes.new(name: "Another", category: @category, monthly_contribution: 5, currency: "USD", starts_on: Date.current)
    assert_not dup.valid?
    assert_includes dup.errors[:category], "That category already backs another envelope."
  end

  test "rejects a category whose parent already backs another envelope" do
    parent = Category.create!(name: "Bills test", family: @family, color: "#6471eb", lucide_icon: "house")
    child = Category.create!(name: "Electric test", parent: parent, family: @family)
    @family.envelopes.create!(name: "Bills env", category: parent, monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)

    overlap = @family.envelopes.new(name: "Electric env", category: child, monthly_contribution: 5, currency: "USD", starts_on: Date.current.beginning_of_month)
    assert_not overlap.valid?
    assert_includes overlap.errors[:category], "A parent or sub-category of this category already backs another envelope."
  end

  test "rejects a category whose subcategory already backs another envelope" do
    parent = Category.create!(name: "Bills2 test", family: @family, color: "#6471eb", lucide_icon: "house")
    child = Category.create!(name: "Water test", parent: parent, family: @family)
    @family.envelopes.create!(name: "Water env", category: child, monthly_contribution: 5, currency: "USD", starts_on: Date.current.beginning_of_month)

    overlap = @family.envelopes.new(name: "Bills env", category: parent, monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)
    assert_not overlap.valid?
  end

  test "category must belong to the same family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign_category = Category.create!(name: "Foreign", family: other_family, color: "#4da568", lucide_icon: "plane")
    envelope = @family.envelopes.new(name: "X", category: foreign_category, monthly_contribution: 5, currency: "USD", starts_on: Date.current)
    assert_not envelope.valid?
    assert_includes envelope.errors[:category], "The category must belong to the same family as the envelope."
  end

  test "target_date requires a target_amount" do
    envelope = @family.envelopes.new(name: "X", monthly_contribution: 5, currency: "USD", starts_on: Date.current, target_date: Date.current)
    assert_not envelope.valid?
  end

  # --- Contribution accrual (running balance, no monthly reset) ---

  test "months_elapsed counts the start month immediately" do
    assert_equal 1, build_envelope(months_ago: 0).months_elapsed
  end

  test "months_elapsed accumulates indefinitely across months" do
    assert_equal 4, build_envelope(months_ago: 3).months_elapsed
  end

  test "total_contributed is the monthly amount times months elapsed" do
    envelope = build_envelope(months_ago: 2, monthly_contribution: 350)
    assert_equal 1050.to_d, envelope.total_contributed # 350 * 3 (start month + 2)
  end

  test "balance keeps accruing across months with no reset" do
    envelope = build_envelope(months_ago: 5, monthly_contribution: 200)
    # No spend → balance is the full six months of contributions.
    assert_equal 1200.to_d, envelope.current_balance
  end

  # --- Spend debits ---

  test "a transaction in the category debits the envelope" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    create_transaction(account: @account, amount: 120, date: Date.current, category: @category)

    assert_equal 120.to_d, envelope.total_spent
    assert_equal 380.to_d, envelope.current_balance # 500 - 120
  end

  test "spend accumulates across multiple transactions" do
    envelope = build_envelope(months_ago: 1, monthly_contribution: 300)
    create_transaction(account: @account, amount: 100, date: Date.current, category: @category)
    create_transaction(account: @account, amount: 50, date: 1.month.ago.to_date, category: @category)

    assert_equal 150.to_d, envelope.total_spent
    assert_equal 450.to_d, envelope.current_balance # 600 - 150
  end

  test "a refund (negative amount) credits back into the envelope" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    create_transaction(account: @account, amount: 200, date: Date.current, category: @category)
    create_transaction(account: @account, amount: -75, date: Date.current, category: @category)

    assert_equal 125.to_d, envelope.total_spent # 200 - 75
    assert_equal 375.to_d, envelope.current_balance
  end

  test "spend before the start date is ignored" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    create_transaction(account: @account, amount: 999, date: 2.months.ago.to_date, category: @category)

    assert_equal 0.to_d, envelope.total_spent
  end

  test "transactions in other categories are ignored" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    other = Category.create!(name: "Other test", family: @family, color: "#6471eb", lucide_icon: "shapes")
    create_transaction(account: @account, amount: 300, date: Date.current, category: other)

    assert_equal 0.to_d, envelope.total_spent
  end

  test "subcategory spend rolls up into the envelope" do
    sub = Category.create!(name: "Flights test", parent: @category, family: @family)
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    create_transaction(account: @account, amount: 80, date: Date.current, category: sub)

    assert_equal 80.to_d, envelope.total_spent
  end

  test "pending transactions are excluded from spend" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    pending = create_transaction(account: @account, amount: 100, date: Date.current, category: @category)
    pending.transaction.update!(extra: { "plaid" => { "pending" => true } })

    assert_equal 0.to_d, envelope.total_spent
  end

  test "user-excluded entries are excluded from spend" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    excluded = create_transaction(account: @account, amount: 100, date: Date.current, category: @category)
    excluded.update!(excluded: true)

    assert_equal 0.to_d, envelope.total_spent
  end

  test "budget-excluded kinds (transfers, CC payments) do not debit the envelope" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 500)
    create_transaction(account: @account, amount: 100, date: Date.current, category: @category, kind: "funds_movement")
    create_transaction(account: @account, amount: 80, date: Date.current, category: @category, kind: "cc_payment")

    assert_equal 0.to_d, envelope.total_spent
    assert_equal 500.to_d, envelope.current_balance
  end

  test "recent_entries excludes budget-excluded kinds" do
    envelope = build_envelope(months_ago: 0)
    spend = create_transaction(account: @account, amount: 50, date: Date.current, category: @category)
    transfer = create_transaction(account: @account, amount: 75, date: Date.current, category: @category, kind: "funds_movement")

    ids = envelope.recent_entries.map(&:id)
    assert_includes ids, spend.id
    assert_not_includes ids, transfer.id
  end

  test "recent_entries excludes pending transactions" do
    envelope = build_envelope(months_ago: 0)
    posted = create_transaction(account: @account, amount: 50, date: Date.current, category: @category)
    pending = create_transaction(account: @account, amount: 75, date: Date.current, category: @category)
    pending.transaction.update!(extra: { "plaid" => { "pending" => true } })

    ids = envelope.recent_entries.map(&:id)
    assert_includes ids, posted.id
    assert_not_includes ids, pending.id
  end

  test "recent_entries exposes the amount converted to the envelope currency" do
    envelope = build_envelope(months_ago: 0) # USD
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.1, date: Date.current)
    create_transaction(account: @account, amount: 100, currency: "EUR", date: Date.current, category: @category)

    entry = envelope.recent_entries.first
    assert_equal 110.to_d, entry.converted_amount.to_d # 100 EUR * 1.1
  end

  test "an envelope with no category has zero spend" do
    envelope = @family.envelopes.create!(name: "No cat", monthly_contribution: 100, currency: "USD", starts_on: Date.current.beginning_of_month)
    create_transaction(account: @account, amount: 500, date: Date.current, category: @category)

    assert_equal 0.to_d, envelope.total_spent
  end

  # --- Negative balance handling ---

  test "envelope is allowed to go negative when overspent" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 100)
    create_transaction(account: @account, amount: 250, date: Date.current, category: @category)

    assert envelope.current_balance.negative?
    assert envelope.negative?
    assert_equal(-150.to_d, envelope.current_balance) # 100 - 250
  end

  test "status is :negative when overspent regardless of target" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 100, target_amount: 1000)
    create_transaction(account: @account, amount: 250, date: Date.current, category: @category)

    assert_equal :negative, envelope.status
  end

  # --- Sinking fund vs virtual goal modes ---

  test "sinking fund has no target" do
    envelope = build_envelope(months_ago: 0, target_amount: nil)
    assert envelope.sinking_fund?
    assert_not envelope.has_target?
    assert_nil envelope.progress_percent
    assert_nil envelope.remaining_amount
    assert_equal :tracking, envelope.status
  end

  test "virtual goal exposes progress, remaining and reached" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 400, target_amount: 1000)
    assert envelope.has_target?
    assert_not envelope.sinking_fund?
    assert_equal 40, envelope.progress_percent # 400 of 1000
    assert_equal 600.to_d, envelope.remaining_amount
    assert_not envelope.reached?
    assert_equal :on_track, envelope.status
  end

  test "virtual goal is reached when balance meets target" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 1000, target_amount: 1000)
    assert envelope.reached?
    assert_equal 100, envelope.progress_percent
    assert_equal 0.to_d, envelope.remaining_amount
    assert_equal :reached, envelope.status
  end

  test "progress_percent is clamped between 0 and 100" do
    over = build_envelope(months_ago: 0, monthly_contribution: 5000, target_amount: 1000, category: nil)
    assert_equal 100, over.progress_percent

    under = build_envelope(months_ago: 0, monthly_contribution: 100, target_amount: 1000)
    create_transaction(account: @account, amount: 300, date: Date.current, category: @category)
    assert_equal 0, under.progress_percent # negative balance clamps to 0
  end

  test "months_to_target projects from the monthly contribution" do
    envelope = build_envelope(months_ago: 0, monthly_contribution: 100, target_amount: 500)
    # Balance is 100 (one month), 400 remaining at 100/mo → 4 months.
    assert_equal 4, envelope.months_to_target
  end

  test "months_to_target is nil without a target" do
    assert_nil build_envelope(months_ago: 0, target_amount: nil).months_to_target
  end
end
