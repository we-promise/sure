require "test_helper"

class Insight::Generators::FixedCommitmentsRatioGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    travel_to Date.new(2026, 11, 16)
    @family = families(:dylan_family)
    # `depository` is shared with every member; `connected` is private to the admin.
    @shared = accounts(:depository)
    @private = accounts(:connected)

    Entry.where(account_id: @family.accounts.select(:id), entryable_type: "Transaction").delete_all
    @family.recurring_transactions.destroy_all
  end

  test "flags commitments rising exactly the threshold against six months ago" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)

    insight = generate.sole

    assert_equal "fixed_commitments_ratio", insight.insight_type
    assert_equal "fixed_commitments_ratio", insight.dedup_key
    assert_equal "medium", insight.priority
    assert_equal 35, insight.metadata[:current_band]
    assert insight.metadata[:accounts_digest].present?
    assert_equal "35.0", insight.facts[:current_ratio]
    assert_equal "30.0", insight.facts[:previous_ratio]
    assert_includes insight.facts[:explanation], "Gym (new"
    assert_not_includes insight.facts[:explanation], "Rent"
  end

  test "stays quiet just under the rise threshold" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 199.6, since: 2.months.ago)

    assert_empty generate
  end

  test "flags crossing half of income even when the rise is small" do
    monthly_income(4_000)
    commitment("Rent", 1_900, since: 2.years.ago)
    commitment("Phone", 100, since: 2.months.ago)

    insight = generate.sole

    assert_equal "high", insight.priority
    assert_equal I18n.t("insights.titles.fixed_commitments_ratio.over_half"), insight.title
    assert_equal "50.0", insight.facts[:current_ratio]
  end

  test "stays quiet just under half of income" do
    monthly_income(4_000)
    commitment("Rent", 1_900, since: 2.years.ago)
    commitment("Phone", 96, since: 2.months.ago)

    assert_empty generate
  end

  test "stays quiet when commitments were already above half six months ago" do
    monthly_income(4_000)
    commitment("Rent", 2_400, since: 2.years.ago)
    commitment("Phone", 100, since: 2.months.ago)

    assert_empty generate
  end

  # Rent paid for years but declared today: history is backfilled for six
  # months only, so its first occurrence lands at the edge of that window.
  test "a long-standing bill declared today with backfilled history is not new" do
    monthly_income(4_000)
    rent = commitment("Rent", 1_600, since: Date.current, manual: true)
    RecurringTransaction::OccurrenceGenerator.new(rent).backfill!(from: 6.months.ago.to_date)

    assert_empty generate
  end

  test "a bill declared going forward says nothing about before and is not new" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    declared = commitment("Insurance", 400, since: Date.current)
    declared.update_columns(anchor_date: Date.current.next_month.beginning_of_month)

    assert_empty generate
  end

  test "a declared bill with a past first due date is new from that date" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    declared = commitment("Insurance", 200, since: Date.current)
    declared.update_columns(anchor_date: 2.months.ago.to_date)

    assert_includes generate.sole.facts[:explanation], "Insurance (new"
  end

  test "returns nothing when no commitment was in force six months ago" do
    monthly_income(4_000)
    commitment("Gym", 1_000, since: 2.months.ago)

    assert_empty generate
  end

  test "a price rise counts as a contributor with the amount it added" do
    monthly_income(4_000)
    rent = commitment("Rent", 1_400, since: 2.years.ago)
    rent.recurring_price_changes.create!(effective_on: 3.months.ago.to_date, previous_amount: 1_200,
                                         new_amount: 1_400, currency: "USD", source: "user")

    insight = generate.sole

    assert_equal "35.0", insight.facts[:current_ratio]
    assert_equal "30.0", insight.facts[:previous_ratio]
    assert_includes insight.facts[:explanation], "Rent ($200.00 a month more)"
  end

  test "a series that replaced another reads as raised, not new" do
    monthly_income(4_000)
    commitment("Rent", 1_000, since: 2.years.ago)
    old_plan = commitment("Phone plan", 200, since: 2.years.ago, status: "ended",
                          cancelled_on: 2.months.ago.to_date, last_occurrence_date: 2.months.ago.to_date)
    new_plan = commitment("Phone plan v2", 400, since: 2.months.ago)
    old_plan.update_columns(replaced_by_id: new_plan.id)

    assert_includes generate.sole.facts[:explanation], "Phone plan v2 ($200.00 a month more)"
  end

  test "a series that ended since counts six months ago, so a swap is not a rise" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Old gym", 200, since: 2.years.ago, status: "ended", cancelled_on: 2.months.ago.to_date,
               last_occurrence_date: 2.months.ago.to_date)
    commitment("New gym", 200, since: 2.months.ago)

    assert_empty generate
  end

  # Today: rent + gym = 1,600 (40%). Six months ago: rent + club + magazine
  # = 1,800 (45%). Without them back then this would read as a 10-point rise.
  test "a series paused or gone stale since counts six months ago but not today" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 400, since: 2.months.ago)
    commitment("Paused club", 400, since: 2.years.ago, status: "paused", last_occurrence_date: 3.months.ago.to_date)
    commitment("Stale magazine", 200, since: 2.years.ago, status: "inactive", last_occurrence_date: 3.months.ago.to_date)

    assert_empty generate
  end

  test "a series that stopped before six months ago counts on neither side" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    commitment("Paused club", 400, since: 2.years.ago, status: "paused", last_occurrence_date: 8.months.ago.to_date)

    insight = generate.sole

    assert_equal "35.0", insight.facts[:current_ratio]
    assert_equal "30.0", insight.facts[:previous_ratio]
  end

  # An annual bill's previous payment can sit beyond the backfilled history,
  # so one first seen two months ago is the edge of that history, not new.
  test "a dismissed suggestion never counts six months ago" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    dismissed = commitment("Detected club", 400, since: 2.years.ago, status: "ended",
                           last_occurrence_date: 2.months.ago.to_date)
    dismissed.recurring_occurrences.delete_all

    insight = generate.sole

    assert_equal "30.0", insight.facts[:previous_ratio]
  end

  # A pause records no date, and the last payment of an annual bill can sit
  # months before the reference date while the bill was still in force.
  test "a paused annual bill counts six months ago through the cycle its last payment covers" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    insurance = commitment("Insurance", 2_400, since: 2.years.ago, status: "paused",
                           last_occurrence_date: Date.new(2026, 1, 1))
    RecurringTransaction::FrequencyPreset.apply(insurance, preset: "annual", day_of_month: "1", month_of_year: "1")
    insurance.save!

    # Six months ago 1,200 + 200 a month of insurance = 35%; today 1,400 = 35%.
    assert_empty generate
  end

  test "prices six months ago on the last day of the earlier window, even in a shorter month" do
    travel_to Date.new(2026, 5, 16)
    monthly_income(4_000)
    rent = commitment("Rent", 1_400, since: 2.years.ago)
    # The earlier window ends on 31 October 2025; shifting 30 April back six
    # months lands on 30 October instead.
    rent.recurring_price_changes.create!(effective_on: Date.new(2025, 10, 31), previous_amount: 1_200,
                                         new_amount: 1_400, currency: "USD", source: "user")

    assert_empty generate
  end

  test "an acknowledged rise does not reopen when the ratio falls into a lower band" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    @family.insights.create!(insight_type: "fixed_commitments_ratio", priority: "medium", status: "dismissed",
                             title: "t", body: "b", dedup_key: "fixed_commitments_ratio",
                             metadata: { "current_band" => 40 }, generated_at: 1.hour.ago)

    assert_equal 40, generate.sole.metadata[:current_band]
  end

  # An acknowledged row is not expired when its condition clears, so the
  # last time the job regenerated it is what says whether the rise stayed live.
  test "a rise that cleared after being acknowledged comes back visible at a lower band" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    acknowledged = @family.insights.create!(insight_type: "fixed_commitments_ratio", priority: "medium",
                                            status: "dismissed", title: "t", body: "b", dedup_key: "fixed_commitments_ratio",
                                            metadata: { "current_band" => 40 }, generated_at: 3.days.ago)
    @family.users.each { |user| user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true)) }

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert acknowledged.reload.active?
    assert_equal 35, acknowledged.metadata["current_band"]
  end

  test "a rise that cleared after being acknowledged comes back visible in the same band" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    acknowledged = travel_to(3.days.ago) do
      @family.insights.create!(insight_type: "fixed_commitments_ratio", priority: "medium",
                               status: "dismissed", title: "t", body: "b", dedup_key: "fixed_commitments_ratio",
                               metadata: JSON.parse(generate.sole.metadata.to_json), generated_at: Time.current)
    end
    @family.users.each { |user| user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true)) }

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert acknowledged.reload.active?
    assert_equal 35, acknowledged.metadata["current_band"]
  end

  test "an acknowledged rise that stays live keeps its metadata" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    acknowledged = travel_to(1.day.ago) do
      @family.insights.create!(insight_type: "fixed_commitments_ratio", priority: "medium",
                               status: "dismissed", title: "t", body: "b", dedup_key: "fixed_commitments_ratio",
                               metadata: JSON.parse(generate.sole.metadata.to_json), generated_at: Time.current)
    end

    assert_equal acknowledged.metadata, JSON.parse(generate.sole.metadata.to_json)
  end

  test "an expired rise starts again from the current band" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    @family.insights.create!(insight_type: "fixed_commitments_ratio", priority: "medium", status: "expired",
                             title: "t", body: "b", dedup_key: "fixed_commitments_ratio",
                             metadata: { "current_band" => 40 }, generated_at: 1.month.ago)

    assert_equal 35, generate.sole.metadata[:current_band]
  end

  test "normalises annual and weekly cadences to a month" do
    monthly_income(4_000)
    commitment("Rent", 1_000, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    insurance = commitment("Insurance", 2_400, since: 2.months.ago)
    RecurringTransaction::FrequencyPreset.apply(insurance, preset: "annual", day_of_month: "1", month_of_year: "9")
    insurance.save!
    cleaner = commitment("Cleaner", 10, since: 2.months.ago)
    RecurringTransaction::FrequencyPreset.apply(cleaner, preset: "weekly", weekday: "1")
    cleaner.save!

    insight = generate.sole

    # Today 1,000 + 200 + 2,400 / 12 + 10 × 52.18 / 12 = 1,443.48; then 1,000 + 200.
    assert_equal "36.1", insight.facts[:current_ratio]
    assert_equal "30.0", insight.facts[:previous_ratio]
    assert_includes insight.facts[:explanation], "Cleaner (new, $43.48"
    assert_not_includes insight.facts[:explanation], "Insurance"
  end

  test "leaves out a series in a currency without an exchange rate" do
    ExchangeRate.stubs(:provider).returns(nil)
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)
    commitment("Tokyo storage", 50_000, since: 2.months.ago, currency: "JPY")

    assert_equal "35.0", generate.sole.facts[:current_ratio]
  end

  test "explains a rise caused by lower income" do
    monthly_income(3_000, months: 1..6)
    monthly_income(4_000, months: 7..12)
    commitment("Rent", 1_200, since: 2.years.ago)

    insight = generate.sole

    assert_equal "40.0", insight.facts[:current_ratio]
    assert_includes insight.facts[:explanation], "$3,000.00"
    assert_includes insight.facts[:explanation], "$4,000.00"
  end

  test "mentions income alongside new commitments when it drove at least half the rise" do
    monthly_income(3_000, months: 1..6)
    monthly_income(4_000, months: 7..12)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 100, since: 2.months.ago)

    explanation = generate.sole.facts[:explanation]

    assert_includes explanation, "Gym (new"
    assert_includes explanation, "$3,000.00"
  end

  test "leaves income out of the explanation when it drove less than half the rise" do
    monthly_income(3_800, months: 1..6)
    monthly_income(4_000, months: 7..12)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)

    explanation = generate.sole.facts[:explanation]

    assert_includes explanation, "Gym (new"
    assert_not_includes explanation, "$3,800.00"
  end

  test "uses the median income so a bonus month does not hide the rise" do
    monthly_income(4_000)
    income_in(2, 12_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)

    assert_equal "35.0", generate.sole.facts[:current_ratio]
  end

  test "leaves out income on an account that is private to one member" do
    monthly_income(4_000)
    6.times { |offset| create_transaction(account: @private, amount: -4_000, name: "Private salary",
                                          date: (Date.current.beginning_of_month << (offset + 1)).change(day: 20)) }
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)

    insight = generate.sole

    assert_equal "35.0", insight.facts[:current_ratio]
    assert_equal "$4,000.00", insight.facts[:income]
  end

  test "counts recurring payments into a loan but not into other accounts" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    shared_loan, shared_asset = accounts(:loan), accounts(:other_asset)
    [ shared_loan, shared_asset ].each do |account|
      AccountShare.create!(account: account, user: users(:family_member), permission: "read_only")
    end
    commitment("Mortgage payment", 400, since: 2.months.ago, destination_account: shared_loan)
    commitment("Savings sweep", 400, since: 2.months.ago, destination_account: shared_asset)

    assert_equal "40.0", generate.sole.facts[:current_ratio]
  end

  test "leaves out series on an account that is private to one member" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Private club", 400, since: 2.months.ago, account: @private)

    assert_empty generate
  end

  test "returns nothing without income six months ago to compare with" do
    monthly_income(4_000, months: 1..6)
    commitment("Rent", 1_200, since: 2.years.ago)

    assert_empty generate
  end

  test "returns nothing without recurring commitments" do
    monthly_income(4_000)

    assert_empty generate
  end

  test "returns nothing when recurring transactions are disabled" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 400, since: 2.months.ago)
    @family.update!(recurring_transactions_disabled: true)

    assert_empty generate
  end

  test "writes the body in English and Spanish" do
    monthly_income(4_000)
    commitment("Rent", 1_200, since: 2.years.ago)
    commitment("Gym", 200, since: 2.months.ago)

    %i[en es].each do |locale|
      I18n.with_locale(locale) do
        insight = generate.sole
        body = Insight::BodyWriter.new.write(insight)

        assert_includes body, "Gym"
        assert_includes body, { en: "35.0%", es: "35,0%" }.fetch(locale)
        assert_no_match(/translation missing/i, body)
        assert_no_match(/translation missing/i, insight.title)
      end
    end
  end

  private
    def generate
      Insight::Generators::FixedCommitmentsRatioGenerator.new(@family).generate
    end

    # Income on the 15th of each of the given complete months back from today.
    def monthly_income(amount, months: 1..12)
      months.each { |offset| income_in(offset, amount) }
    end

    def income_in(months_ago, amount)
      create_transaction(account: @shared, amount: -amount, name: "Salary",
                         date: (Date.current.beginning_of_month << months_ago).change(day: 15))
    end

    # A detected series whose first payment was on `since`. One first paid
    # before six months ago was already known to Sure then; a recent one was
    # confirmed today, with its history backfilled from that first payment.
    def commitment(name, amount, since:, account: @shared, currency: "USD", **attributes)
      since = since.to_date
      series = @family.recurring_transactions.create!(
        name: name, account: account, amount: amount, currency: currency, expected_day_of_month: 1,
        last_occurrence_date: Date.current.beginning_of_month, next_expected_date: Date.current.next_month.beginning_of_month,
        status: "active", manual: false, **attributes
      )
      series.update_columns(created_at: since < Date.current << 6 ? since : Time.current)
      series.recurring_occurrences.delete_all
      series.recurring_occurrences.create!(family: @family, original_due_on: since, due_on: since, currency: currency)
      series
    end
end
