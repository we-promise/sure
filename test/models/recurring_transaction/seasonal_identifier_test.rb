require "test_helper"

class RecurringTransaction::SeasonalIdentifierTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
  end

  def charge(name:, amount:, date:, account: @account)
    Entry.create!(
      account: account,
      name: name,
      date: date,
      amount: amount,
      currency: account.currency,
      entryable: Transaction.new
    )
  end

  def identify
    RecurringTransaction::SeasonalIdentifier.new(@family).identify!
  end

  # ---- the case that started this ------------------------------------------

  test "detects quarterly tax instalments the monthly pass cannot see" do
    [ 0, 91, 182, 273 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 273 + offset)
    end

    created = identify

    assert_equal 1, created.size
    series = created.first
    assert_equal "IMPOTS ACOMPTE", series.name
    assert_equal "suggested", series.status
    assert_equal 4, series.occurrence_count
    assert_equal "quarterly", RecurringTransaction::FrequencyPreset.detect(series).key
  end

  test "the created series projects forward on its real cadence" do
    [ 0, 91, 182 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 182 + offset)
    end

    series = identify.first
    occurrences = series.schedule.occurrences_between(Date.current, Date.current + 365)

    assert occurrences.size.between?(3, 5),
           "a quarterly series must produce about four dates a year, got #{occurrences.size}"
  end

  test "detects an annual premium from only two occurrences" do
    charge(name: "ASSURANCE HABITATION", amount: 340, date: Date.current - 365)
    charge(name: "ASSURANCE HABITATION", amount: 355, date: Date.current - 5)

    series = identify.first

    assert_not_nil series
    assert_equal "annual", RecurringTransaction::FrequencyPreset.detect(series).key
  end

  test "detects a semiannual cadence" do
    charge(name: "CONTROLE TECHNIQUE", amount: 90, date: Date.current - 364)
    charge(name: "CONTROLE TECHNIQUE", amount: 90, date: Date.current - 182)
    charge(name: "CONTROLE TECHNIQUE", amount: 92, date: Date.current)

    assert_equal "semiannual", RecurringTransaction::FrequencyPreset.detect(identify.first).key
  end

  # ---- what it must NOT claim -----------------------------------------------

  test "leaves monthly patterns to the monthly pass" do
    6.times { |i| charge(name: "NETFLIX", amount: 15, date: Date.current - (i * 30)) }

    assert_empty identify
  end

  test "rejects charges whose spacing is not consistent" do
    charge(name: "RANDOM SHOP", amount: 200, date: Date.current - 400)
    charge(name: "RANDOM SHOP", amount: 200, date: Date.current - 200)
    charge(name: "RANDOM SHOP", amount: 200, date: Date.current - 30)

    assert_empty identify, "gaps of 200 and 170 days are not a cadence"
  end

  test "rejects a single occurrence" do
    charge(name: "ONE OFF", amount: 500, date: Date.current - 10)

    assert_empty identify
  end

  test "ignores small amounts where two occurrences prove little" do
    charge(name: "TINY THING", amount: 3, date: Date.current - 365)
    charge(name: "TINY THING", amount: 3, date: Date.current - 2)

    assert_empty identify
  end

  test "ignores a cadence that has clearly lapsed" do
    charge(name: "OLD SUBSCRIPTION", amount: 200, date: Date.current - 800)
    charge(name: "OLD SUBSCRIPTION", amount: 200, date: Date.current - 435)

    assert_empty identify, "an annual charge last seen 14 months ago is cancelled, not seasonal"
  end

  test "ignores transfers between the user's own accounts" do
    [ 0, 91, 182 ].each do |offset|
      entry = charge(name: "INTERNAL MOVE", amount: 300, date: Date.current - 182 + offset)
      entry.entryable.update!(kind: "funds_movement")
    end

    assert_empty identify
  end

  test "ignores income" do
    [ 0, 182, 364 ].each do |offset|
      charge(name: "ANNUAL BONUS", amount: -2_000, date: Date.current - 364 + offset)
    end

    assert_empty identify, "this pass is about obligations, not earnings"
  end

  test "ignores amounts that drift beyond the clustering tolerance" do
    charge(name: "VARIABLE THING", amount: 100, date: Date.current - 365)
    charge(name: "VARIABLE THING", amount: 900, date: Date.current - 3)

    assert_empty identify
  end

  # ---- never touches what the user already decided --------------------------

  test "does not duplicate a series the user already declared" do
    @family.recurring_transactions.create!(
      name: "IMPOTS ACOMPTE", amount: 110, currency: @account.currency, account: @account,
      manual: true, status: "active", expected_day_of_month: 15,
      last_occurrence_date: Date.current - 10, next_expected_date: Date.current + 80
    )

    [ 0, 91, 182 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 182 + offset)
    end

    assert_empty identify
  end

  test "does not resurrect a series the user ended" do
    @family.recurring_transactions.create!(
      name: "IMPOTS ACOMPTE", amount: 110, currency: @account.currency, account: @account,
      manual: true, status: "inactive", expected_day_of_month: 15,
      last_occurrence_date: Date.current - 10, next_expected_date: Date.current + 80
    )

    [ 0, 91, 182 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 182 + offset)
    end

    assert_empty identify
  end

  test "claims by identity even when the amount has drifted a lot between years" do
    @family.recurring_transactions.create!(
      name: "ASSURANCE", amount: 200, currency: @account.currency, account: @account,
      manual: true, status: "active", expected_day_of_month: 15,
      last_occurrence_date: Date.current - 10, next_expected_date: Date.current + 80
    )

    charge(name: "ASSURANCE", amount: 400, date: Date.current - 365)
    charge(name: "ASSURANCE", amount: 430, date: Date.current)

    assert_empty identify, "indexation must not create a second series for the same obligation"
  end

  test "running twice creates nothing the second time" do
    [ 0, 91, 182 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 182 + offset)
    end

    assert_equal 1, identify.size
    assert_empty identify
  end

  # ---- wiring --------------------------------------------------------------

  test "the pipeline leaves the seasonal pass off by default" do
    [ 0, 91, 182 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 182 + offset)
    end

    RecurringTransaction::Pipeline.new(@family).run!

    assert_empty @family.recurring_transactions.where(name: "IMPOTS ACOMPTE"),
                 "the debounced post-sync path must not pay for a 24-month scan"
  end

  test "the pipeline runs the seasonal pass when asked" do
    [ 0, 91, 182 ].each do |offset|
      charge(name: "IMPOTS ACOMPTE", amount: 110, date: Date.current - 182 + offset)
    end

    RecurringTransaction::Pipeline.new(@family).run!(seasonal: true)

    assert @family.recurring_transactions.exists?(name: "IMPOTS ACOMPTE")
  end
end
