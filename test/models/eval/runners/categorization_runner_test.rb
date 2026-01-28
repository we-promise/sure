require "test_helper"

class Eval::Runners::CategorizationRunnerTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @categories = [
      { "id" => "food", "name" => "Food & Drink", "classification" => "expense" },
      { "id" => "fast_food", "name" => "Fast Food", "classification" => "expense", "parent_id" => "food" }
    ]
  end


  test "run processes all samples and calculates metrics" do
    dataset = Eval::Dataset.create!(
      name: "test_cat_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )

    sample1 = dataset.samples.create!(
      input_data: { "id" => "txn_1", "amount" => 10, "classification" => "expense", "description" => "McDonalds" },
      expected_output: { "category_name" => "Fast Food" },
      context_data: { "categories" => @categories },
      difficulty: "easy"
    )

    sample2 = dataset.samples.create!(
      input_data: { "id" => "txn_2", "amount" => 100, "classification" => "expense", "description" => "ATM Withdrawal" },
      expected_output: { "category_name" => nil },
      context_data: { "categories" => @categories },
      difficulty: "edge_case"
    )

    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: "gpt-4.1",
      name: "test_run",
      provider_config: { "access_token" => "test-token" },
      status: "pending"
    )

    mock_response = provider_success_response([
      Provider::LlmConcept::AutoCategorization.new(transaction_id: sample1.id, category_name: "Fast Food"),
      Provider::LlmConcept::AutoCategorization.new(transaction_id: sample2.id, category_name: "null")
    ])

    Provider::Openai.any_instance.stubs(:auto_categorize).returns(mock_response)

    runner = Eval::Runners::CategorizationRunner.new(eval_run)
    result = runner.run

    assert_equal "completed", result.status
    assert_equal 2, result.results.count
    assert result.metrics["accuracy"].present?
  end

  test "records correct result when category matches" do
    dataset = Eval::Dataset.create!(
      name: "test_cat_match_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )

    sample = dataset.samples.create!(
      input_data: { "id" => "txn_1", "amount" => 10, "classification" => "expense", "description" => "McDonalds" },
      expected_output: { "category_name" => "Fast Food" },
      context_data: { "categories" => @categories },
      difficulty: "easy"
    )

    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: "gpt-4.1",
      name: "test_run",
      provider_config: { "access_token" => "test-token" },
      status: "pending"
    )

    mock_response = provider_success_response([
      Provider::LlmConcept::AutoCategorization.new(transaction_id: sample.id, category_name: "Fast Food")
    ])

    Provider::Openai.any_instance.stubs(:auto_categorize).returns(mock_response)

    runner = Eval::Runners::CategorizationRunner.new(eval_run)
    runner.run

    result = eval_run.results.find_by(eval_sample_id: sample.id)

    assert result.correct
    assert result.exact_match
    assert_equal "Fast Food", result.actual_output["category_name"]
  end

  test "records hierarchical match when parent category returned" do
    dataset = Eval::Dataset.create!(
      name: "test_cat_hier_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )

    sample = dataset.samples.create!(
      input_data: { "id" => "txn_3", "amount" => 50, "classification" => "expense", "description" => "Olive Garden" },
      expected_output: { "category_name" => "Fast Food" },
      context_data: { "categories" => @categories },
      difficulty: "medium"
    )

    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: "gpt-4.1",
      name: "test_hierarchical",
      provider_config: { "access_token" => "test-token" },
      status: "pending"
    )

    # Model returns parent category instead of subcategory
    mock_response = provider_success_response([
      Provider::LlmConcept::AutoCategorization.new(transaction_id: sample.id, category_name: "Food & Drink")
    ])

    Provider::Openai.any_instance.stubs(:auto_categorize).returns(mock_response)

    runner = Eval::Runners::CategorizationRunner.new(eval_run)
    runner.run

    result = eval_run.results.find_by(eval_sample_id: sample.id)

    assert_not result.exact_match
    assert result.hierarchical_match
  end

  test "handles null correctly when expected" do
    dataset = Eval::Dataset.create!(
      name: "test_cat_null_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )

    sample = dataset.samples.create!(
      input_data: { "id" => "txn_2", "amount" => 100, "classification" => "expense", "description" => "ATM Withdrawal" },
      expected_output: { "category_name" => nil },
      context_data: { "categories" => @categories },
      difficulty: "edge_case"
    )

    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: "gpt-4.1",
      name: "test_run",
      provider_config: { "access_token" => "test-token" },
      status: "pending"
    )

    mock_response = provider_success_response([
      Provider::LlmConcept::AutoCategorization.new(transaction_id: sample.id, category_name: "null")
    ])

    Provider::Openai.any_instance.stubs(:auto_categorize).returns(mock_response)

    runner = Eval::Runners::CategorizationRunner.new(eval_run)
    runner.run

    result = eval_run.results.find_by(eval_sample_id: sample.id)

    assert result.correct
    assert result.null_expected
    assert result.null_returned
  end

  test "records error results on provider error but completes run" do
    dataset = Eval::Dataset.create!(
      name: "test_cat_err_#{SecureRandom.hex(4)}",
      eval_type: "categorization",
      version: "1.0"
    )

    sample = dataset.samples.create!(
      input_data: { "id" => "txn_1", "amount" => 10, "classification" => "expense", "description" => "McDonalds" },
      expected_output: { "category_name" => "Fast Food" },
      context_data: { "categories" => @categories },
      difficulty: "easy"
    )

    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: "gpt-4.1",
      name: "test_run",
      provider_config: { "access_token" => "test-token" },
      status: "pending"
    )

    Provider::Openai.any_instance.stubs(:auto_categorize).raises(StandardError.new("API Error"))

    runner = Eval::Runners::CategorizationRunner.new(eval_run)
    result = runner.run

    # Run completes but with error results
    assert_equal "completed", result.status
    assert_equal 1, result.results.count

    error_result = result.results.find_by(eval_sample_id: sample.id)
    assert_not error_result.correct
    assert_includes error_result.actual_output["error"], "API Error"
  end
end
