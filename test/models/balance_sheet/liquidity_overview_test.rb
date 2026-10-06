require "test_helper"

class BalanceSheet::LiquidityOverviewTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:empty)
    @today = Date.new(2026, 10, 5)
  end

  test "splits assets into available and locked and deducts short-term debts" do
    create_account(name: "Checking", balance: 3_000, accountable: Depository.new(subtype: "checking"))
    create_account(name: "Brokerage", balance: 7_000, accountable: Investment.new(subtype: "brokerage"))
    create_account(name: "Term deposit", balance: 5_000, accountable: Depository.new(subtype: "cd"),
                   liquidity_choice: "locked", available_on: @today + 40)
    create_account(name: "House", balance: 100_000, accountable: Property.new)
    create_account(name: "Card", balance: 400, accountable: CreditCard.new)
    create_account(name: "Mortgage", balance: 80_000, accountable: Loan.new)

    overview = overview_on(@today)

    assert_equal 10_000, overview.available_assets.amount
    assert_equal 105_000, overview.bound_assets.amount
    assert_equal 400, overview.short_term_liabilities.amount
    assert_equal 9_600, overview.available_net_worth.amount
    assert_equal BalanceSheet.new(@family).assets.total, overview.total_assets.amount
    assert_in_delta 8.7, overview.available_share, 0.1
  end

  test "a locked account counts as available from its release date" do
    create_account(name: "Term deposit", balance: 5_000, accountable: Depository.new(subtype: "cd"),
                   liquidity_choice: "locked", available_on: @today + 1)

    assert_equal 0, overview_on(@today).available_assets.amount
    assert_equal 5_000, overview_on(@today + 1).available_assets.amount
    assert_equal [ "immediate" ], overview_on(@today + 1).asset_levels.map(&:key)
  end

  test "groups assets by the level that applies on the date" do
    create_account(name: "Checking", balance: 1_000, accountable: Depository.new(subtype: "checking"))
    create_account(name: "Brokerage", balance: 3_000, accountable: Investment.new(subtype: "brokerage"))
    create_account(name: "Car", balance: 6_000, accountable: Vehicle.new)

    levels = overview_on(@today).asset_levels

    assert_equal %w[immediate short_term long_term], levels.map(&:key)
    assert_equal [ 1_000, 3_000, 6_000 ], levels.map { |level| level.total.amount }
    assert_equal [ 10.0, 30.0, 60.0 ], levels.map(&:weight)
  end

  test "release timeline buckets locked money by release date" do
    create_locked("Soon", 1_000, @today + 30)
    create_locked("This year", 2_000, @today + 200)
    create_locked("In two years", 3_000, @today + 700)
    create_locked("Far", 4_000, @today + 2_000)
    create_locked("Undated", 5_000, nil)
    create_account(name: "Pension", balance: 6_000, accountable: Investment.new(subtype: "401k"))

    totals = overview_on(@today).release_buckets.to_h { |bucket| [ bucket.key, bucket.total.amount ] }

    assert_equal(
      { "within_3_months" => 1_000, "within_12_months" => 2_000, "within_36_months" => 3_000,
        "later" => 4_000, "no_date" => 5_000, "long_term" => 6_000 },
      totals
    )
  end

  test "lists releases soonest first with sums per year" do
    create_locked("B", 2_000, Date.new(2027, 3, 1))
    create_locked("A", 1_000, Date.new(2026, 12, 1))
    create_locked("C", 4_000, Date.new(2027, 8, 1))

    overview = overview_on(@today)

    assert_equal %w[A B C], overview.releases.map { |release| release.account.name }
    assert_equal 57, overview.releases.first.days
    assert_equal({ 2026 => 1_000, 2027 => 6_000 }, overview.releases_by_year.transform_values(&:amount))
    assert_equal "A", overview.next_release.account.name
  end

  test "an automatically renewing deposit is listed at its next renewal date" do
    account = create_locked("Rolling", 1_000, @today - 10)
    account.update!(auto_renew: true, renewal_term_months: 3)

    overview = overview_on(@today)

    assert_equal 0, overview.available_assets.amount
    assert_equal (@today - 10) >> 3, overview.releases.sole.date
    assert overview.releases.sole.auto_renew
  end

  test "leaves out accounts excluded from reports" do
    create_account(name: "Checking", balance: 1_000, accountable: Depository.new(subtype: "checking"))
    create_account(name: "Hidden", balance: 9_000, accountable: Depository.new(subtype: "checking"), exclude_from_reports: true)

    assert_equal 1_000, overview_on(@today).available_assets.amount
  end

  test "available net worth series counts locked money from its release date" do
    period = Period.custom(start_date: Date.current - 2.days, end_date: Date.current)
    checking = create_account(name: "Checking", balance: 1_000, accountable: Depository.new(subtype: "checking"))
    deposit = create_locked("Term deposit", 5_000, Date.current - 1.day)
    card = create_account(name: "Card", balance: 200, accountable: CreditCard.new)
    house = create_account(name: "House", balance: 50_000, accountable: Property.new)

    [ checking, deposit, card, house ].each do |account|
      period.start_date.upto(period.end_date) { |date| create_balance(account: account, date: date, balance: account.balance) }
    end

    values = BalanceSheet.new(@family).available_net_worth_series(period: period).values.to_h { |value| [ value.date, value.value.amount ] }

    assert_equal 800, values.fetch(period.start_date)
    assert_equal 5_800, values.fetch(period.start_date + 1.day)
    assert_equal 5_800, values.fetch(period.end_date)
  end

  private
    def create_account(attributes = {})
      @family.accounts.create!(currency: "USD", **attributes)
    end

    def create_locked(name, balance, available_on)
      create_account(name: name, balance: balance, accountable: Depository.new(subtype: "cd"),
                     liquidity_choice: "locked", available_on: available_on)
    end

    def overview_on(date)
      BalanceSheet.new(@family).liquidity(date: date)
    end
end
