require "test_helper"

class Eval::LangfuseExperimentRunnerTest < ActiveSupport::TestCase
  test "runs an experiment with dataset identity and observation scores" do
    dataset = stub(name: "categories", eval_type: "categorization", sample_count: 1)
    exporter = mock
    exporter.expects(:export)
    Eval::Langfuse::DatasetExporter.expects(:new).with(dataset, client: anything).returns(exporter)
    client = mock
    client.expects(:get_dataset).with(name: "eval_categories").returns({ "id" => "dataset-id" })
    client.expects(:get_dataset_items).with(dataset_name: "eval_categories", page: 1, limit: 50).returns({ "data" => [ {
      "id" => "item-id", "input" => { "transaction" => { "description" => "Coffee" }, "categories" => [ { "name" => "Dining" } ] },
      "expectedOutput" => { "category_name" => "Dining" }, "metadata" => { "difficulty" => "easy" }
    } ] })
    observation = stub(id: "trace-id", span_id: "span-id")
    client.expects(:create_experiment_item).with do |args|
      args[:dataset_id] == "dataset-id" && args[:item_id] == "item-id" && args[:experiment_id].present? &&
        args[:experiment_name] == "candidate" && args[:output] == "Dining" &&
        args[:expected_output] == { "category_name" => "Dining" } && args[:metadata]["difficulty"] == "easy"
    end.returns(observation)
    client.expects(:create_score).with(trace_id: "trace-id", observation_id: "span-id", name: "accuracy", value: 1.0, comment: "Correct")
    client.expects(:shutdown)
    provider = mock
    provider.expects(:auto_categorize).returns(Provider::Response.new(success?: true, error: nil,
      data: [ Provider::LlmConcept::AutoCategorization.new(transaction_id: "item-id", category_name: "Dining") ]))
    runner = Eval::Langfuse::ExperimentRunner.new(dataset, model: "gpt-4.1", client: client)
    runner.stubs(:llm_provider).returns(provider)

    result = runner.run(run_name: "candidate")

    assert_equal "candidate", result[:run_name]
    assert_equal 1, result[:samples_processed]
    assert_equal 100.0, result[:metrics][:accuracy]
  end
end
