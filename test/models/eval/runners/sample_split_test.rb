require "test_helper"

class Eval::Runners::SampleSplitTest < ActiveSupport::TestCase
  setup do
    @dataset = Eval::Dataset.create!(
      name: "split_test_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )
  end

  test "keeps every null-expected sample out of training" do
    4.times { |i| sample(difficulty: "easy", category: "Groceries", id_hint: "e#{i}") }
    3.times { |i| sample(difficulty: "edge_case", category: nil, id_hint: "n#{i}") }

    split = Eval::Runners::SampleSplit.new(@dataset.samples)

    assert split.train.all? { |s| s.expected_category_name.present? },
      "Bayes trains on categorized transactions only, so a null-expected sample cannot train"
    assert_equal 3, split.test.count { |s| s.expected_category_name.nil? }
  end

  test "stratifies the categorized samples by difficulty" do
    6.times { |i| sample(difficulty: "easy", category: "Groceries", id_hint: "e#{i}") }
    6.times { |i| sample(difficulty: "hard", category: "Shopping", id_hint: "h#{i}") }

    split = Eval::Runners::SampleSplit.new(@dataset.samples, train_ratio: 0.5)

    # Without stratification a seeded shuffle could hand training every easy
    # sample and leave a uniformly hard test set.
    assert_equal 3, split.train.count { |s| s.difficulty == "easy" }
    assert_equal 3, split.train.count { |s| s.difficulty == "hard" }
  end

  test "is deterministic for a given seed and differs across seeds" do
    10.times { |i| sample(difficulty: "easy", category: "Groceries", id_hint: "e#{i}") }

    first = Eval::Runners::SampleSplit.new(@dataset.samples, seed: 42).train.map(&:id)
    again = Eval::Runners::SampleSplit.new(@dataset.samples, seed: 42).train.map(&:id)
    other = Eval::Runners::SampleSplit.new(@dataset.samples, seed: 7).train.map(&:id)

    assert_equal first, again, "same seed must reproduce the split so legs stay comparable"
    assert_not_equal first, other
  end

  test "train and test partition the dataset without overlap" do
    8.times { |i| sample(difficulty: "medium", category: "Groceries", id_hint: "m#{i}") }
    2.times { |i| sample(difficulty: "edge_case", category: nil, id_hint: "n#{i}") }

    split = Eval::Runners::SampleSplit.new(@dataset.samples)

    assert_empty split.train.map(&:id) & split.test.map(&:id)
    assert_equal @dataset.samples.count, split.train.size + split.test.size
  end

  test "describe reports the composition the test set actually has" do
    6.times { |i| sample(difficulty: "easy", category: "Groceries", id_hint: "e#{i}") }
    4.times { |i| sample(difficulty: "edge_case", category: nil, id_hint: "n#{i}") }

    describe = Eval::Runners::SampleSplit.new(@dataset.samples, train_ratio: 0.5).describe

    assert_equal 3, describe["train_size"]
    assert_equal 7, describe["test_size"]
    assert_equal 4, describe["test_null_expected"]
  end

  test "rejects an unknown role" do
    assert_raises(ArgumentError) { Eval::Runners::SampleSplit.new(@dataset.samples).for_role("holdout") }
  end

  private
    def sample(difficulty:, category:, id_hint:)
      @dataset.samples.create!(
        difficulty: difficulty,
        input_data: { "id" => id_hint, "description" => "TXN #{id_hint}", "amount" => 10 },
        expected_output: { "category_name" => category },
        context_data: { "categories" => [ { "id" => "groceries", "name" => "Groceries" } ] }
      )
    end
end
