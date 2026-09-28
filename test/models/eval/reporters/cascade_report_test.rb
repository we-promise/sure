require "test_helper"

class Eval::Reporters::CascadeReportTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "cascade_test_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
    # 4 samples: Bayes will cover the first two and decline the last two.
    @samples = 4.times.map { |i| build_sample("s#{i}") }
  end

  test "scores the provider on the residual, not the whole test set" do
    bayes = bayes_run(covered: { 0 => true, 1 => true }, declined: [ 2, 3 ])
    # Provider is right on both easy rows it would never see, and wrong on both
    # residual rows. Full-set accuracy 50%, residual accuracy 0% — the whole
    # point of the report is that those are different numbers.
    provider = provider_run("jev", correct_indexes: [ 0, 1 ])

    summary = Eval::Reporters::CascadeReport.new(bayes_run: bayes, provider_runs: [ provider ]).summary
    jev = summary[:providers]["jev:~typesafe/jev-latest"]

    assert_equal 50.0, jev[:full_accuracy]
    assert_equal 0.0, jev[:residual_accuracy], "must score only the rows Bayes declined"
    assert_equal 2, jev[:residual_scored]
  end

  test "declining is never scored as a correct answer" do
    # Sample 3 is null-expected. Bayes declining it is correct cascade
    # behaviour, but it is not Bayes answering "no category" — the provider
    # stage still has to resolve it.
    @samples[3].update!(expected_output: { "category_name" => nil })
    bayes = bayes_run(covered: { 0 => true, 1 => true }, declined: [ 2, 3 ])

    summary = Eval::Reporters::CascadeReport.new(bayes_run: bayes, provider_runs: []).summary

    assert_equal 2, summary[:bayes][:covered]
    assert_equal 2, summary[:bayes][:declined]
    assert_equal 100.0, summary[:bayes][:accuracy_on_covered]
    assert_equal 50.0, summary[:bayes][:coverage]
  end

  test "warns when a provider ran on a different split" do
    bayes = bayes_run(covered: { 0 => true }, declined: [ 1, 2, 3 ])
    provider = provider_run("jev", correct_indexes: [ 1 ])
    provider.update!(provider_config: { "split_role" => "test", "split_seed" => 999, "split_ratio" => 0.5 })

    output = Eval::Reporters::CascadeReport.new(bayes_run: bayes, provider_runs: [ provider ]).to_s

    assert_match(/WARNING/, output)
    assert_match(/different split/, output)
  end

  test "states the dataset-shape limitation in the output" do
    bayes = bayes_run(covered: { 0 => true }, declined: [ 1, 2, 3 ])

    output = Eval::Reporters::CascadeReport.new(bayes_run: bayes, provider_runs: []).to_s

    # A reader quoting the Bayes number needs to see why it is a lower bound.
    assert_match(/worst case/, output)
    assert_match(/understates/, output)
  end

  test "flags zero coverage as unmeasured rather than as a result" do
    # Measured on categorization_golden_v2: Bayes covers nothing, because a
    # golden set has ~one transaction per merchant and so no vocabulary to
    # generalize from. A reader must not carry that away as "Bayes classified
    # nothing".
    bayes = bayes_run(covered: {}, declined: [ 0, 1, 2, 3 ])
    report = Eval::Reporters::CascadeReport.new(bayes_run: bayes, provider_runs: [])

    assert report.degenerate_bayes?
    output = report.to_s
    assert_match(/DOES NOT MEASURE BAYES/, output)
    assert_match(/not as zero/, output)
    assert_no_match(/worst case/, output, "the softer caveat should be replaced, not appended")
  end

  test "reports cascade totals across both stages" do
    bayes = bayes_run(covered: { 0 => true, 1 => false }, declined: [ 2, 3 ])
    provider = provider_run("jev", correct_indexes: [ 2 ])

    output = Eval::Reporters::CascadeReport.new(bayes_run: bayes, provider_runs: [ provider ]).to_s

    # 1 correct from Bayes + 1 correct from the provider on the residual = 2/4.
    assert_match(%r{bayes \+ jev.*2 / 4}, output)
  end

  private
    def build_sample(hint)
      @dataset.samples.create!(
        difficulty: "medium",
        input_data: { "id" => hint, "description" => "TXN #{hint}", "amount" => 10 },
        expected_output: { "category_name" => "Groceries" },
        context_data: { "categories" => [ { "id" => "groceries", "name" => "Groceries" } ] }
      )
    end

    def bayes_run(covered:, declined:)
      run = Eval::Run.create!(
        dataset: @dataset, provider: "bayes", model: "naive-bayes", status: "pending",
        provider_config: { "split_role" => "test", "split_seed" => 42, "split_ratio" => 0.5 }
      )

      covered.each do |index, correct|
        run.results.create!(
          sample: @samples[index], actual_output: { "category_name" => "Groceries" },
          correct: correct, metadata: { "declined" => false, "confidence" => 0.9 }
        )
      end

      declined.each do |index|
        run.results.create!(
          sample: @samples[index], actual_output: { "category_name" => nil },
          correct: false, null_expected: @samples[index].expected_category_name.nil?,
          metadata: { "declined" => true }
        )
      end

      run
    end

    def provider_run(provider, correct_indexes:)
      run = Eval::Run.create!(
        dataset: @dataset, provider: provider, model: "~typesafe/jev-latest", status: "pending",
        provider_config: { "split_role" => "test", "split_seed" => 42, "split_ratio" => 0.5 }
      )

      @samples.each_with_index do |sample, index|
        run.results.create!(
          sample: sample, actual_output: { "category_name" => "Groceries" },
          correct: correct_indexes.include?(index)
        )
      end

      run
    end
end
