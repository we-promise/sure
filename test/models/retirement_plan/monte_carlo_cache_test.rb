require "test_helper"

class RetirementPlan::MonteCarloCacheTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    RetirementPlan.where(user: @user).delete_all
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @plan = RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2045, 1, 1))
    @as_of = Date.new(2026, 11, 23)
  end

  # A fresh instance, as each request gets: the plan memoises its converted streams.
  def plan
    RetirementPlan.find(@plan.id)
  end

  def key
    RetirementPlan::MonteCarloCache.key(plan, as_of: @as_of)
  end

  test "the first fetch runs the plan and the next one reads it back" do
    RetirementPlan::MonteCarlo.any_instance.expects(:success_rate).once.returns(0.9)

    first = RetirementPlan::MonteCarloCache.fetch(plan, as_of: @as_of)
    second = RetirementPlan::MonteCarloCache.fetch(plan, as_of: @as_of)

    assert_equal 0.9, first[:success_rate]
    assert_equal first, second
  end

  # The page draws no percentile paths, and they cost a further full run.
  test "the result is the plan's run without the percentile paths" do
    expected = plan.monte_carlo_result(as_of: @as_of).except(:percentiles)
    RetirementPlan::MonteCarlo.any_instance.expects(:percentiles).never

    assert_equal expected, RetirementPlan::MonteCarloCache.fetch(plan, as_of: @as_of)
  end

  test "a plan with nothing to run caches nothing, so a later fetch tries again" do
    RetirementPlan.any_instance.expects(:monte_carlo).twice.returns(nil)

    2.times { assert_nil RetirementPlan::MonteCarloCache.fetch(plan, as_of: @as_of) }
  end

  # A result cached by older code is not read back under a changed shape.
  test "the key carries the cache's version" do
    assert_includes key, "/v#{RetirementPlan::MonteCarloCache::VERSION}/"
  end

  test "the key is the same for the same inputs, and changes with each input the run reads" do
    assert_equal key, key

    changes = {
      "a setting" => -> { @plan.update!(return_volatility: BigDecimal("0.2")) },
      "a stream" => -> { @plan.streams.create!(kind: "income", name: "Pension", annual_amount: 12_000, source: "manual") },
      "the date" => -> { @as_of = @as_of.next_day },
      "spending" => -> { IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1234")) },
      "the funded assets" => -> { RetirementPlan.any_instance.stubs(:funding_total).returns(BigDecimal("98765")) }
    }
    changes.each do |what, change|
      before = key
      change.call
      assert_not_equal before, key, "changing #{what} must change the key"
    end
  end

  # A stream left out for want of a rate is part of the inputs: when the rate
  # arrives the stream joins the run, so the key must change with it.
  test "the key changes when a stream left out for want of a rate can be converted" do
    ExchangeRate.stubs(:provider).returns(nil)
    @plan.streams.create!(kind: "expense", name: "Rent abroad", annual_amount: 10_000, currency: "EUR", source: "manual")
    assert_equal 1, plan.unconverted_stream_count(as_of: @as_of), "the stream must start unconverted"
    before = key

    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @as_of, rate: 1.1)

    assert_equal 0, plan.unconverted_stream_count(as_of: @as_of), "the rate must now convert it"
    assert_not_equal before, key
  end

  # Streams are converted at the stored rate for `as_of`, and a stored rate is
  # revised in place, so a revision must change the key as a new date does.
  test "the key changes when the rate a stream is converted at is revised" do
    ExchangeRate.stubs(:provider).returns(nil)
    rate = ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @as_of, rate: 1.1)
    @plan.streams.create!(kind: "expense", name: "Rent abroad", annual_amount: 10_000, currency: "EUR", source: "manual")
    before = key

    travel 1.minute do
      rate.update!(rate: 1.2)
    end

    assert_not_equal before, key
  end
end
