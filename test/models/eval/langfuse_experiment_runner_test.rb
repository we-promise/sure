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
    scoring = sequence("flush before scoring")
    client.expects(:flush_experiment_items).in_sequence(scoring)
    client.expects(:create_score).with(trace_id: "trace-id", observation_id: "span-id", name: "accuracy", value: 1.0, comment: "Correct").in_sequence(scoring)
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

  [ false, true ].each do |export_fails|
    test "flushes once per batch and #{export_fails ? 'skips scores for failed exports' : 'scores after export'}" do
      dataset = stub(name: "categories", eval_type: "categorization", sample_count: 26)
      exporter = mock
      exporter.expects(:export)
      client = mock
      Eval::Langfuse::DatasetExporter.expects(:new).with(dataset, client: client).returns(exporter)
      client.expects(:get_dataset).returns({ "id" => "dataset-id" })
      items = 26.times.map do |index|
        { "id" => "item-#{index}", "input" => { "description" => "Coffee" }, "expectedOutput" => { "category_name" => "Dining" } }
      end
      client.expects(:get_dataset_items).returns({ "data" => items })
      ordering = sequence("batched export and scores")
      items.each_slice(25).with_index do |batch, index|
        batch.each do |item|
          client.expects(:create_experiment_item).with { |args| args[:item_id] == item["id"] }
            .returns(stub(id: "trace-#{item['id']}", span_id: "span-#{item['id']}")).in_sequence(ordering)
        end
        flush = client.expects(:flush_experiment_items).in_sequence(ordering)
        if export_fails && index.zero?
          flush.raises(Eval::Langfuse::Client::ApiError, "Export failed")
        else
          batch.each do |item|
            client.expects(:create_score).with(trace_id: "trace-#{item['id']}", observation_id: "span-#{item['id']}",
              name: "accuracy", value: 1.0, comment: "Correct").in_sequence(ordering)
          end
        end
      end
      client.expects(:shutdown)
      provider = mock
      provider.expects(:auto_categorize).twice.returns(Provider::Response.new(success?: true, error: nil,
        data: items.map { |item| Provider::LlmConcept::AutoCategorization.new(transaction_id: item["id"], category_name: "Dining") }))
      runner = Eval::Langfuse::ExperimentRunner.new(dataset, model: "gpt-4.1", client: client)
      runner.stubs(:llm_provider).returns(provider)

      result = runner.run(run_name: "candidate")

      assert_equal 26, result[:samples_processed]
      assert_equal export_fails ? 1 : 26, result[:metrics][:correct]
      assert_equal export_fails ? 25 : 0, result[:metrics][:incorrect]
    end
  end

  [ "categorization", "merchant_detection" ].each do |eval_type|
    test "discards queued scores after a partial #{eval_type} batch fails" do
      dataset = stub(name: "transactions", eval_type: eval_type, sample_count: 26)
      exporter = mock
      exporter.expects(:export)
      client = mock
      Eval::Langfuse::DatasetExporter.expects(:new).with(dataset, client: client).returns(exporter)
      client.expects(:get_dataset).returns({ "id" => "dataset-id" })
      items = 26.times.map do |index|
        { "id" => "item-#{index}", "input" => { "description" => "Coffee" },
          "expectedOutput" => { "category_name" => "Dining", "business_name" => "Cafe", "business_url" => "https://cafe.test" } }
      end
      client.expects(:get_dataset_items).returns({ "data" => items })
      client.expects(:create_experiment_item).with { |args| args[:item_id] == "item-0" }
        .returns(stub(id: "trace-0", span_id: "span-0"))
      client.expects(:create_experiment_item).with { |args| args[:item_id] == "item-1" }
        .raises(Eval::Langfuse::Client::ApiError, "Observation creation failed")
      client.expects(:create_experiment_item).with { |args| args[:item_id] == "item-25" }
        .returns(stub(id: "trace-25", span_id: "span-25"))
      client.expects(:flush_experiment_items).twice
      client.expects(:create_score).with(trace_id: "trace-25", observation_id: "span-25", name: "accuracy", value: 1.0, comment: "Correct")
      client.expects(:shutdown)
      provider = mock
      if eval_type == "categorization"
        data = items.map { |item| Provider::LlmConcept::AutoCategorization.new(transaction_id: item["id"], category_name: "Dining") }
        provider.expects(:auto_categorize).twice.returns(Provider::Response.new(success?: true, error: nil, data: data))
      else
        data = items.map { |item| Provider::LlmConcept::AutoDetectedMerchant.new(transaction_id: item["id"], business_name: "Cafe", business_url: "https://cafe.test") }
        provider.expects(:auto_detect_merchants).twice.returns(Provider::Response.new(success?: true, error: nil, data: data))
      end
      runner = Eval::Langfuse::ExperimentRunner.new(dataset, model: "gpt-4.1", client: client)
      runner.stubs(:llm_provider).returns(provider)

      result = runner.run(run_name: "candidate")

      assert_equal 26, result[:samples_processed]
      assert_equal 1, result[:metrics][:correct]
      assert_equal 25, result[:metrics][:incorrect]
    end
  end
end
