require "test_helper"

class Eval::DatasetTest < ActiveSupport::TestCase
  test "validates presence of name and eval_type" do
    dataset = Eval::Dataset.new

    assert_not dataset.valid?
    assert_includes dataset.errors[:name], "can't be blank"
    assert_includes dataset.errors[:eval_type], "can't be blank"
  end

  test "validates eval_type is one of allowed values" do
    dataset = Eval::Dataset.new(name: "test", eval_type: "invalid")

    assert_not dataset.valid?
    assert_includes dataset.errors[:eval_type], "is not included in the list"

    dataset.eval_type = "categorization"
    dataset.valid?
    assert_empty dataset.errors[:eval_type]
  end

  test "validates name uniqueness" do
    Eval::Dataset.create!(name: "unique_test", eval_type: "categorization")

    duplicate = Eval::Dataset.new(name: "unique_test", eval_type: "categorization")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "scopes filter by eval_type" do
    cat_dataset = Eval::Dataset.create!(name: "cat_test", eval_type: "categorization")
    merch_dataset = Eval::Dataset.create!(name: "merch_test", eval_type: "merchant_detection")
    chat_dataset = Eval::Dataset.create!(name: "chat_test", eval_type: "chat")

    assert_includes Eval::Dataset.for_categorization, cat_dataset
    assert_not_includes Eval::Dataset.for_categorization, merch_dataset

    assert_includes Eval::Dataset.for_merchant_detection, merch_dataset
    assert_not_includes Eval::Dataset.for_merchant_detection, cat_dataset

    assert_includes Eval::Dataset.for_chat, chat_dataset
    assert_not_includes Eval::Dataset.for_chat, cat_dataset
  end

  test "import_from_yaml creates dataset with samples" do
    yaml_content = <<~YAML
      name: test_import
      description: Test dataset
      eval_type: categorization
      version: "1.0"
      context:
        categories:
          - id: "food"
            name: "Food"
            classification: "expense"
      samples:
        - id: sample_1
          difficulty: easy
          tags: [test]
          input:
            id: txn_1
            amount: 10
            classification: expense
            description: "Test transaction"
          expected:
            category_name: "Food"
    YAML

    file_path = Rails.root.join("tmp", "test_import.yml")
    File.write(file_path, yaml_content)

    dataset = Eval::Dataset.import_from_yaml(file_path)

    assert_equal "test_import", dataset.name
    assert_equal "categorization", dataset.eval_type
    assert_equal 1, dataset.samples.count
    assert_equal "easy", dataset.samples.first.difficulty
    assert_equal "Food", dataset.samples.first.expected_output["category_name"]
  ensure
    File.delete(file_path) if File.exist?(file_path)
  end

  test "statistics returns sample breakdown" do
    dataset = Eval::Dataset.create!(name: "stats_test", eval_type: "categorization")

    dataset.samples.create!(
      input_data: { id: "1" },
      expected_output: { category_name: "Food" },
      difficulty: "easy",
      tags: [ "food" ]
    )

    dataset.samples.create!(
      input_data: { id: "2" },
      expected_output: { category_name: "Travel" },
      difficulty: "medium",
      tags: [ "travel" ]
    )

    stats = dataset.statistics

    assert_equal 2, stats[:total_samples]
    assert_equal({ "easy" => 1, "medium" => 1 }, stats[:by_difficulty])
    assert_includes stats[:by_tags], "food"
    assert_includes stats[:by_tags], "travel"
  end

  test "runner_class returns correct class for each eval_type" do
    cat_dataset = Eval::Dataset.new(eval_type: "categorization")
    merch_dataset = Eval::Dataset.new(eval_type: "merchant_detection")
    chat_dataset = Eval::Dataset.new(eval_type: "chat")

    assert_equal Eval::Runners::CategorizationRunner, cat_dataset.runner_class
    assert_equal Eval::Runners::MerchantDetectionRunner, merch_dataset.runner_class
    assert_equal Eval::Runners::ChatRunner, chat_dataset.runner_class
  end
end
