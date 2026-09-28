require "test_helper"

class Demo::GeneratorTest < ActiveSupport::TestCase
  setup do
    @family = Family.create!(name: "Demo Family")
    @admin_user = create_user!(@family, "demo-admin@example.com")
  end

  test "monitoring api key creation reassigns stale demo monitoring key owned by another user" do
    stale_family = Family.create!(name: "Old Demo Family")
    stale_user = create_user!(stale_family, "old-demo-admin@example.com")
    stale_key = stale_user.api_keys.create!(
      name: "monitoring",
      key: ApiKey::DEMO_MONITORING_KEY,
      scopes: [ "read" ],
      source: "monitoring"
    )

    monitoring_key = Demo::Generator.new.send(:create_monitoring_api_key!, @family)

    assert_equal stale_key.id, monitoring_key.id
    assert_equal @admin_user, monitoring_key.user
    assert_equal "monitoring", monitoring_key.source
    assert_equal [ "read" ], monitoring_key.scopes
    assert_equal 1, ApiKey.where(display_key: ApiKey::DEMO_MONITORING_KEY).count
  end

  test "monitoring api key creation reuses the current admin user's key" do
    existing_key = @admin_user.api_keys.create!(
      name: "monitoring",
      key: ApiKey::DEMO_MONITORING_KEY,
      scopes: [ "read" ],
      source: "monitoring"
    )

    monitoring_key = Demo::Generator.new.send(:create_monitoring_api_key!, @family)

    assert_equal existing_key, monitoring_key
    assert_equal 1, ApiKey.where(display_key: ApiKey::DEMO_MONITORING_KEY).count
  end

  # Regression for a `rake demo_data:default` crash: the goal-seeding matrix
  # linked several active goals to the same account as a 100%-whole-account
  # claim each, which violates GoalAccount#whole_account_link_must_be_exclusive
  # the moment the second one tries to save.
  test "generate_goals! seeds the full matrix without raising" do
    @family.update!(currency: "USD")
    @family.accounts.create!(accountable: Depository.new, name: "Primary Checking",
                              currency: @family.currency, balance: 150_000)
    @family.accounts.create!(accountable: Depository.new, name: "Secondary Savings",
                              currency: @family.currency, balance: 10_000)

    assert_difference "@family.goals.count", 9 do
      Demo::Generator.new.send(:generate_goals!, @family)
    end
  end

  # The demo family's loans were bare Loan.new records -- no rate, no term, and
  # the mortgage's principal a transaction rather than an opening valuation --
  # so none of them had a schedule to show. The mortgage is adjustable with
  # recorded changes, so the demo shows a schedule re-amortising; the other two
  # are fixed.
  test "demo loans carry the terms and principal a schedule is built from" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    generator.send(:generate_major_purchases!)

    mortgage = @family.accounts.find_by!(name: "Home Mortgage").loan
    assert mortgage.variable_rate_type?, "the demo mortgage should be adjustable"
    assert_equal BigDecimal("320000"), mortgage.original_balance.amount
    assert_equal mortgage.start_date, mortgage.origination_date
    assert mortgage.amortization_schedule.re_amortising?,
      "a recorded rate change must move the demo mortgage's repayment"

    [ "Car Loan", "Student Loan" ].each do |name|
      loan = @family.accounts.find_by!(name: name).loan
      assert_not loan.variable_rate_type?, "#{name} should be fixed"
      assert loan.amortization_schedule&.payments&.any?, "#{name} should have a schedule"
    end
  end

  # Owner review of #3474: the demo loans' figures must add up. Each loan pays
  # its own schedule's principal and interest and nothing else moves its
  # balance, so today it owes what its schedule says -- except the student
  # loan, which made one extra payment (2,000, a year ago) and so is ahead of
  # its schedule for a real reason.
  test "demo loans owe what their own schedules say, the student loan ahead by its extra payment" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    generator.send(:generate_housing_transactions!)
    generator.send(:generate_transportation_transactions!)
    generator.send(:generate_major_purchases!)
    generator.send(:generate_loan_payments!)
    checking = generator.instance_variable_get(:@chase_checking)
    today = Date.current

    { "Home Mortgage" => 0, "Car Loan" => 0, "Student Loan" => 2_000 }.each do |name, extra|
      account = @family.accounts.find_by!(name: name)
      Sync.create!(syncable: account).perform
      due = account.reload.loan.amortization_schedule.payments.select { |payment| payment.date <= today }
      assert due.any?, "#{name} must have payments due, or this asserts nothing"
      assert_in_delta due.last.ending_balance.amount - extra, account.balance, 0.01,
        "#{name} must owe its schedule's balance today#{" less its extra payment" if extra.positive?}"
    end

    student = @family.accounts.find_by!(name: "Student Loan").loan
    due = student.amortization_schedule.payments.select { |payment| payment.date <= today }
    booked_interest = checking.entries.where(name: "Student Loan Payment Interest").sum(:amount)
    assert_in_delta due.sum { |payment| payment.interest.amount }, booked_interest, 0.01,
      "the interest booked must be the schedule's interest, not a flat figure"
  end

  private
    def create_user!(family, email)
      family.users.create!(
        first_name: "Demo",
        last_name: "Admin",
        email: email,
        password: "password123",
        role: :admin,
        onboarded_at: Time.current,
        ai_enabled: true,
        show_sidebar: true,
        show_ai_sidebar: true,
        ui_layout: :dashboard
      )
    end
end
