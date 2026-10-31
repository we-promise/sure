require "test_helper"

class Eval::Metrics::BaseTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "test_cost_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
    @run = Eval::Run.create!(
      dataset: @dataset, provider: "jev", model: "jev-latest",
      name: "cost", status: "running"
    )
  end

  # costs: array of cost-or-nil, one per sample
  def record(costs)
    costs.each_with_index do |cost, index|
      sample = @dataset.samples.create!(
        input_data: { "description" => "txn #{index}" },
        expected_output: { "category_name" => "Coffee" },
        difficulty: "easy"
      )
      @run.results.create!(
        sample: sample,
        actual_output: { "category_name" => "Coffee" },
        correct: true,
        cost: cost
      )
    end
  end

  def metrics
    Eval::Metrics::CategorizationMetrics.new(@run)
  end

  test "reports no cost when the provider priced nothing" do
    record([ nil, nil, nil ])

    # TypeSafe's native API returns token counts without a settled price, and
    # the OpenAI path never populates cost at all. `sum` returns 0 over
    # all-NULL, which would report a paid provider as free.
    calculated = metrics.calculate

    assert_nil calculated[:total_cost]
    assert_nil calculated[:cost_per_sample]
  end

  test "reports a measured zero as zero" do
    record([ 0.0, 0.0 ])

    # A genuinely free run is a different claim from an unmeasured one, and
    # must survive the guard that suppresses the latter.
    calculated = metrics.calculate

    assert_equal 0.0, calculated[:total_cost]
    assert_equal 0.0, calculated[:cost_per_sample]
  end

  test "totals cost when only some samples are priced" do
    record([ 0.002, nil, 0.004 ])

    # Partial instrumentation is still a real figure, but it is a floor rather
    # than a total — averaged over every sample, not only the priced ones.
    calculated = metrics.calculate

    assert_in_delta 0.006, calculated[:total_cost], 0.000001
    assert_in_delta 0.002, calculated[:cost_per_sample], 0.000001
  end

  test "stores nil rather than zero on a run that priced nothing" do
    record([ nil, nil ])

    @run.complete!(metrics.calculate)

    # Eval::Reporters::ComparisonReporter picks the cheapest run with
    # `total_cost || Float::INFINITY`, so a stored 0 would beat every
    # instrumented run and crown whichever provider measures cost least.
    assert_nil @run.reload.total_cost
  end

  test "stores the total on a run that priced its calls" do
    record([ 0.001, 0.003 ])

    @run.complete!(metrics.calculate)

    assert_in_delta 0.004, @run.reload.total_cost.to_f, 0.000001
  end
end
