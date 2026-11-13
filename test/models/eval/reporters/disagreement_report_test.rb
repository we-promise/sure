require "test_helper"

class Eval::Reporters::DisagreementReportTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "test_disagree_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
    @baseline = run_for("openai", "gpt-4o")
    @candidate = run_for("jev", "jev-latest")
    @samples = []
  end

  def run_for(provider, model)
    Eval::Run.create!(
      dataset: @dataset, provider: provider, model: model,
      name: "#{provider}_#{model}", status: "completed"
    )
  end

  def sample!(description = "txn #{@samples.size}")
    @samples << @dataset.samples.create!(
      input_data: { "description" => description },
      expected_output: { "category_name" => "Coffee" },
      difficulty: "easy"
    )
    @samples.last
  end

  def answer(run, sample, category)
    run.results.create!(
      sample: sample,
      actual_output: { "category_name" => category },
      correct: category == "Coffee"
    )
  end

  # baseline answer, candidate answer — "Coffee" is correct
  def scenario(pairs)
    pairs.each do |base_answer, cand_answer|
      s = sample!
      answer(@baseline, s, base_answer)
      answer(@candidate, s, cand_answer)
    end
    Eval::Reporters::DisagreementReport.new(@baseline, @candidate)
  end

  test "splits paired results into wins, losses and shared failures" do
    report = scenario([
      [ "Coffee", "Coffee" ],   # both correct
      [ "Rent",   "Coffee" ],   # candidate wins
      [ "Coffee", "Rent" ],     # candidate loses
      [ "Rent",   "Rent" ],     # both wrong, same answer
      [ "Rent",   "Travel" ]    # both wrong, different answers
    ])

    assert report.comparable?
    assert_equal 5, report.paired_count
    assert_equal 1, report.both_correct.size
    assert_equal 1, report.candidate_wins.size
    assert_equal 1, report.candidate_losses.size
    assert_equal 1, report.both_wrong_same_answer.size
    assert_equal 1, report.both_wrong_different_answers.size
  end

  test "identical accuracy can still hide completely different error profiles" do
    # Both score 50%, but they fail on disjoint samples — the exact case two
    # accuracy percentages cannot distinguish.
    report = scenario([
      [ "Coffee", "Rent" ],
      [ "Rent",   "Coffee" ]
    ])

    assert_equal 1, report.candidate_wins.size
    assert_equal 1, report.candidate_losses.size
    assert_equal 0, report.both_correct.size
    assert_equal 0.0, report.agreement_rate
  end

  test "agreement rate counts identical answers regardless of correctness" do
    report = scenario([
      [ "Coffee", "Coffee" ],
      [ "Rent",   "Rent" ],
      [ "Rent",   "Travel" ]
    ])

    assert_in_delta 66.67, report.agreement_rate, 0.01
  end

  test "surfaces the regressions a switch would buy" do
    report = scenario([ [ "Coffee", "Rent" ] ])

    example = report.to_h[:examples][:losses].sole
    assert_equal "txn 0", example[:sample]
    assert_equal({ "category_name" => "Coffee" }, example[:expected])
    assert_equal({ "category_name" => "Rent" }, example[:candidate])
    assert_match(/Regressions a switch would buy/, report.to_table)
  end

  test "runs over different datasets are not comparable" do
    other = Eval::Dataset.create!(
      name: "other_#{SecureRandom.hex(4)}", eval_type: "categorization", version: "1.0"
    )
    foreign = Eval::Run.create!(
      dataset: other, provider: "jev", model: "jev-latest", name: "foreign", status: "completed"
    )

    report = Eval::Reporters::DisagreementReport.new(@baseline, foreign)

    assert_not report.comparable?
    assert_equal({ comparable: false }, report.to_h)
    assert_match(/not comparable/, report.to_table)
  end

  test "only pairs samples both runs actually answered" do
    shared = sample!
    answer(@baseline, shared, "Coffee")
    answer(@candidate, shared, "Coffee")

    baseline_only = sample!
    answer(@baseline, baseline_only, "Coffee")

    report = Eval::Reporters::DisagreementReport.new(@baseline, @candidate)

    assert_equal 1, report.paired_count
  end
end
