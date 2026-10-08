require "test_helper"

class RetirementPlanTest < ActiveSupport::TestCase
  include EntriesTestHelper

  AS_OF = Date.new(2026, 3, 15)

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    RetirementPlan.where(user: [ @admin, @member ]).delete_all
    # The fixtures share admin accounts, with their transactions, into the
    # member's finances. Removed so every figure below is made only of what
    # each test adds, and a family-wide scope cannot pass by coincidence.
    AccountShare.where(user: @member).delete_all
  end

  test "a user with no saved plan gets the defaults, and nothing is written" do
    assert_no_difference "RetirementPlan.count" do
      plan = RetirementPlan.for(@admin)

      assert plan.new_record?
      assert_equal @admin, plan.user
      assert_equal BigDecimal("0.04"), plan.safe_withdrawal_rate
      assert_equal BigDecimal("0.05"), plan.expected_annual_return
      assert_nil plan.savings_rate
      assert_nil plan.retirement_date
    end
  end

  test "a user's saved plan is the one returned" do
    saved = RetirementPlan.create!(user: @admin, safe_withdrawal_rate: BigDecimal("0.035"))

    assert_equal saved, RetirementPlan.for(@admin)
    assert RetirementPlan.for(@member).new_record?
  end

  test "a withdrawal rate of zero, above one, or blank is refused" do
    [ 0, BigDecimal("1.5"), nil ].each do |rate|
      plan = RetirementPlan.new(user: @admin, safe_withdrawal_rate: rate)

      assert_not plan.valid?, "#{rate.inspect} should be refused"
      assert plan.errors.key?(:safe_withdrawal_rate)
    end
    assert RetirementPlan.new(user: @admin, safe_withdrawal_rate: 1).valid?
  end

  test "a return of -100% or less, or above 100%, is refused" do
    [ -1, BigDecimal("1.01") ].each do |rate|
      assert_not RetirementPlan.new(user: @admin, expected_annual_return: rate).valid?, "#{rate} should be refused"
    end
    assert RetirementPlan.new(user: @admin, expected_annual_return: BigDecimal("-0.99")).valid?
  end

  test "a savings rate outside 0 to 100% is refused, and a blank one means derive it" do
    assert_not RetirementPlan.new(user: @admin, savings_rate: BigDecimal("-0.01")).valid?
    assert_not RetirementPlan.new(user: @admin, savings_rate: BigDecimal("1.01")).valid?
    assert RetirementPlan.new(user: @admin, savings_rate: nil).valid?
    assert RetirementPlan.new(user: @admin, savings_rate: 0).valid?
  end

  # "abc".to_d is 0, so reading the input that way would save an explicit 0%
  # savings rate, which switches off the derived rate, from a typo.
  test "a percent that is not a number is refused rather than read as zero" do
    plan = RetirementPlan.new(user: @admin, savings_rate: BigDecimal("0.3"))

    plan.savings_rate_percent = "abc"

    assert_not plan.valid?
    assert plan.errors.key?(:savings_rate_percent)
    assert_equal BigDecimal("0.3"), plan.savings_rate, "the value already held is kept"

    plan.savings_rate_percent = "12"

    assert plan.valid?, "a later valid entry clears the error"
    assert_equal BigDecimal("0.12"), plan.savings_rate
  end

  test "the database refuses a withdrawal rate of zero that bypasses the model" do
    plan = RetirementPlan.create!(user: @admin)

    assert_raises(ActiveRecord::StatementInvalid) { plan.update_columns(safe_withdrawal_rate: 0) }
  end

  test "one plan per user" do
    RetirementPlan.create!(user: @admin)

    assert_raises(ActiveRecord::RecordNotUnique) { RetirementPlan.new(user: @admin).save!(validate: false) }
  end

  test "deleting the user deletes their plan" do
    RetirementPlan.create!(user: @member)

    assert_difference "RetirementPlan.count", -1 do
      @member.destroy
    end
  end

  # --- Inputs: what the projection is built from ---------------------------

  test "assets count only the accounts the viewer counts in their finances" do
    own_account(owner: @member, amount: 1_000)
    admins = own_account(owner: @admin, amount: 5_000)
    plan = RetirementPlan.for(@member)

    before = plan.projection(as_of: AS_OF).current_assets
    admins.share_with!(@member, permission: "read_only", include_in_finances: false)
    shared_out = RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets
    AccountShare.where(account: admins, user: @member).update_all(include_in_finances: true)
    shared_in = RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets

    assert_equal BigDecimal("1000"), before
    assert_equal before, shared_out, "an account shared outside the member's finances must not count"
    assert_equal BigDecimal("6000"), shared_in
  end

  test "an admin's own accounts count for the admin" do
    before = RetirementPlan.for(@admin).projection(as_of: AS_OF).current_assets
    own_account(owner: @admin, amount: 5_000)

    assert_equal before + 5_000, RetirementPlan.for(@admin).projection(as_of: AS_OF).current_assets
  end

  test "cash, investments and crypto count as liquid and investment assets; cards, loans and property do not" do
    own_account(owner: @member, amount: 1_000)
    plan = RetirementPlan.for(@member)
    base = plan.projection(as_of: AS_OF).current_assets

    own_account(owner: @member, amount: 700, accountable: CreditCard.new)
    own_account(owner: @member, amount: 90_000, accountable: Loan.new)
    own_account(owner: @member, amount: 400_000, accountable: Property.new)
    assert_equal base, RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets

    own_account(owner: @member, amount: 2_000, accountable: Investment.new)
    own_account(owner: @member, amount: 300, accountable: Crypto.new)
    assert_equal base + 2_300, RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets
  end

  test "each account counts at its latest balance on or before the reference date" do
    account = own_account(owner: @member, amount: 1_000, date: AS_OF - 10)
    Balance.create!(account: account, date: AS_OF - 1, balance: 1_500, currency: "USD")
    Balance.create!(account: account, date: AS_OF + 1, balance: 9_999, currency: "USD")

    assert_equal BigDecimal("1500"), RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets
  end

  test "a balance in another currency is converted at the reference date's rate" do
    own_account(owner: @member, amount: 1_000, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: AS_OF, rate: 1.1)
    # A later rate, so converting at today's date instead would show.
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: AS_OF + 30, rate: 2.0)

    assert_equal BigDecimal("1100"), RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets
  end

  test "an account with no exchange rate is left out, and the plan says how many were" do
    own_account(owner: @member, amount: 1_000)
    own_account(owner: @member, amount: 500, currency: "GBP")
    plan = RetirementPlan.for(@member)

    assert_equal BigDecimal("1000"), plan.projection(as_of: AS_OF).current_assets
    assert_equal 1, plan.unconverted_account_count(as_of: AS_OF)
  end

  test "an account excluded from reports counts in neither assets nor spending" do
    kept = own_account(owner: @member, amount: 1_000)
    create_transaction(account: kept, date: AS_OF, amount: 1_000)
    hidden = own_account(owner: @member, amount: 50_000)
    create_transaction(account: hidden, date: AS_OF, amount: 9_000)
    hidden.update!(exclude_from_reports: true)

    projection = RetirementPlan.for(@member).projection(as_of: AS_OF)

    assert_equal BigDecimal("1000"), projection.current_assets
    assert_equal BigDecimal("12000"), projection.annual_expenses
  end

  test "a disabled account's spending does not count" do
    kept = own_account(owner: @member, amount: 1_000)
    create_transaction(account: kept, date: AS_OF, amount: 1_000)
    closed = own_account(owner: @member, amount: 0)
    create_transaction(account: closed, date: AS_OF, amount: 9_000)
    closed.update_columns(status: "disabled")

    assert_equal BigDecimal("12000"), RetirementPlan.for(@member).projection(as_of: AS_OF).annual_expenses
  end

  test "only the balance in the account's own currency counts" do
    account = own_account(owner: @member, amount: 1_000, date: AS_OF - 1)
    # Later than the USD row, so it is the one taken if currency is ignored.
    Balance.create!(account: account, date: AS_OF, balance: 777, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: AS_OF, rate: 1.1)

    assert_equal BigDecimal("1000"), RetirementPlan.for(@member).projection(as_of: AS_OF).current_assets
  end

  test "spending and income come from the viewer's accounts, not the whole family's" do
    mine = own_account(owner: @member, amount: 1_000)
    theirs = own_account(owner: @admin, amount: 1_000)
    create_transaction(account: mine, date: AS_OF, amount: 1_000)
    create_transaction(account: theirs, date: AS_OF, amount: 5_000)
    create_transaction(account: mine, date: AS_OF, amount: -3_000)

    projection = RetirementPlan.for(@member).projection(as_of: AS_OF)

    assert_equal BigDecimal("12000"), projection.annual_expenses
    assert_equal BigDecimal("36000"), projection.annual_income
  end

  # IncomeStatement counts a transfer into an investment account as an expense.
  # For a FIRE plan that money is saving: counting it as spending would raise
  # the FI number and lower the derived savings rate at the same time.
  test "money moved into investments is saving, not spending" do
    mine = own_account(owner: @member, amount: 1_000)
    create_transaction(account: mine, date: AS_OF, amount: 1_000)
    create_transaction(account: mine, date: AS_OF, amount: 2_000, kind: "investment_contribution")
    create_transaction(account: mine, date: AS_OF, amount: -6_000)

    projection = RetirementPlan.for(@member).projection(as_of: AS_OF)

    assert_equal BigDecimal("12000"), projection.annual_expenses
    assert_equal BigDecimal("300000"), projection.fi_number
  end

  test "the projection runs on the plan's own settings" do
    mine = own_account(owner: @member, amount: 1_000)
    create_transaction(account: mine, date: AS_OF, amount: 1_000)
    plan = RetirementPlan.new(user: @member, safe_withdrawal_rate: BigDecimal("0.05"),
                              expected_annual_return: BigDecimal("0.07"), savings_rate: BigDecimal("0.3"),
                              retirement_date: AS_OF.advance(years: 10))

    projection = plan.projection(as_of: AS_OF)

    assert_equal BigDecimal("240000"), projection.fi_number
    assert_equal BigDecimal("0.07"), projection.expected_annual_return
    assert_equal BigDecimal("0.3"), projection.effective_savings_rate
    assert_equal 10, projection.years_to_retirement
    assert_equal AS_OF, projection.as_of
  end

  private
    def own_account(owner:, amount:, currency: "USD", accountable: Depository.new, date: AS_OF)
      account = Account.create!(
        family: @family, owner: owner, accountable: accountable,
        name: "#{accountable.class.name} #{SecureRandom.hex(3)}", currency: currency, balance: amount
      )
      Balance.create!(account: account, date: date, balance: amount, currency: currency)
      account
    end
end
