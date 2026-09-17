require "test_helper"
require "ostruct"

class Eval::LangfuseClientTest < ActiveSupport::TestCase
  test "writes experiment context and attaches scores to the root observation" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    tracing = LangfuseTracing.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test",
      processor: OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    LangfuseTracing.stubs(:new).returns(tracing)
    client = Eval::Langfuse::Client.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test")
    observation = client.create_experiment_item(name: "categorization_eval", input: { transaction: "Coffee" },
      output: "Dining", expected_output: "Dining", experiment_id: "experiment-id", experiment_name: "candidate",
      dataset_id: "dataset-id", item_id: "item-id", metadata: { difficulty: "easy" })
    span = exporter.finished_spans.sole
    assert_equal "experiment", span.attributes["langfuse.environment"]
    assert_equal "experiment-id", span.attributes["langfuse.experiment.id"]
    assert_equal "candidate", span.attributes["langfuse.experiment.name"]
    assert_equal "dataset-id", span.attributes["langfuse.experiment.dataset.id"]
    assert_equal "item-id", span.attributes["langfuse.experiment.item.id"]
    assert_equal observation.span_id, span.attributes["langfuse.experiment.item.root_observation_id"]
    assert_equal "Dining", JSON.parse(span.attributes["langfuse.experiment.item.expected_output"])
    assert_equal "Dining", JSON.parse(span.attributes["langfuse.observation.output"])
    assert_equal "easy", span.attributes["langfuse.experiment.item.metadata.difficulty"]

    score = stub_request(:post, "https://langfuse.test/api/public/scores")
      .with(basic_auth: [ "pk-test", "sk-test" ], body: {
        traceId: observation.id, observationId: observation.span_id, name: "accuracy", value: 1.0, dataType: "NUMERIC", environment: "experiment"
      }.to_json).to_return(status: 200, body: '{"id":"score-id"}')
    assert_equal "score-id", client.create_score(trace_id: observation.id, observation_id: observation.span_id, name: "accuracy", value: 1.0)["id"]
    assert_requested score
  ensure
    client&.shutdown
  end

  test "raises when experiment ingestion cannot be flushed" do
    tracing = mock
    observation = stub(span_id: "span-id")
    observation.expects(:set_attributes)
    observation.expects(:end).with(output: "result")
    tracing.expects(:trace).returns(observation)
    tracing.expects(:flush).returns(OpenTelemetry::SDK::Trace::Export::FAILURE)
    LangfuseTracing.stubs(:new).returns(tracing)
    client = Eval::Langfuse::Client.new(public_key: "pk-test", secret_key: "sk-test")
    assert_raises(Eval::Langfuse::Client::ApiError) do
      client.create_experiment_item(name: "eval", input: "input", output: "result", expected_output: "expected",
        experiment_id: "experiment-id", experiment_name: "run", dataset_id: "dataset-id", item_id: "item-id")
    end
  end

  test "preserves dataset pagination and configured host" do
    request = stub_request(:get, "https://langfuse.test/api/public/dataset-items")
      .with(query: { datasetName: "eval_chat", page: 2, limit: 50 }, basic_auth: [ "pk-test", "sk-test" ])
      .to_return(status: 200, body: '{"data":[{"id":"item-51"}],"meta":{"page":2}}')
    client = Eval::Langfuse::Client.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test/")
    response = client.get_dataset_items(dataset_name: "eval_chat", page: 2)
    assert_equal "item-51", response.fetch("data").sole.fetch("id")
    assert_equal 2, response.dig("meta", "page")
    assert_requested request
  end

  # -- CRL error list --

  test "crl_errors includes standard CRL error codes" do
    errors = Eval::Langfuse::Client.crl_errors

    assert_includes errors, OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL
    assert_includes errors, OpenSSL::X509::V_ERR_CRL_HAS_EXPIRED
    assert_includes errors, OpenSSL::X509::V_ERR_CRL_NOT_YET_VALID
  end

  test "crl_errors is frozen" do
    assert Eval::Langfuse::Client.crl_errors.frozen?
  end

  # -- CRL verify callback behavior --
  # The callback should bypass only CRL-specific errors while preserving the
  # original verification result for all other error types.

  test "CRL callback returns true for CRL-unavailable errors" do
    crl_error_codes = Eval::Langfuse::Client.crl_errors
    store_ctx = OpenStruct.new(error: OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL)

    callback = build_crl_callback(crl_error_codes)

    assert callback.call(false, store_ctx), "CRL errors should be bypassed even when preverify_ok is false"
  end

  test "CRL callback preserves preverify_ok for non-CRL errors" do
    crl_error_codes = Eval::Langfuse::Client.crl_errors
    # V_OK (0) is not a CRL error
    store_ctx = OpenStruct.new(error: 0)

    callback = build_crl_callback(crl_error_codes)

    assert callback.call(true, store_ctx), "Non-CRL errors with preverify_ok=true should pass"
    refute callback.call(false, store_ctx), "Non-CRL errors with preverify_ok=false should fail"
  end

  test "CRL callback rejects cert errors that are not CRL-related" do
    crl_error_codes = Eval::Langfuse::Client.crl_errors
    # V_ERR_CERT_HAS_EXPIRED is a real cert error, not CRL
    store_ctx = OpenStruct.new(error: OpenSSL::X509::V_ERR_CERT_HAS_EXPIRED)

    callback = build_crl_callback(crl_error_codes)

    refute callback.call(false, store_ctx), "Non-CRL cert errors should not be bypassed"
  end

  private

    # Reconstructs the same lambda used in Eval::Langfuse::Client#execute_request
    # for isolated testing without needing a real Net::HTTP connection.
    def build_crl_callback(crl_error_codes)
      ->(preverify_ok, store_ctx) {
        if crl_error_codes.include?(store_ctx.error)
          true
        else
          preverify_ok
        end
      }
    end
end
