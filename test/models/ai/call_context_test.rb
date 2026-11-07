require "test_helper"

class Ai::CallContextTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @model = ai_model(name: "test-model")
    stub_request(:post, "https://llm.example.test/v1/chat/completions").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ],
              usage: { prompt_tokens: 5, completion_tokens: 1, total_tokens: 6 } }.to_json
    )
  end

  test "RubyLLM's usage event carries the family, the call id and the job's correlation id" do
    usage = capture_ai_events("usage.ruby_llm") do
      Ai::CallContext.job("rule_run:42") do
        with_ai_call_context(feature: :bill_setup, model: @model, family: @family) do |call|
          @call = call
          Ai::Transport.for(@model.endpoint).send(:probe_chat, @model)
        end
      end
    end.sole.payload

    assert_equal @family, usage[:owner]
    assert_equal @call.call_id, usage[:workflow_id]
    assert_equal "rule_run:42", usage[:workflow_parent_id]
    assert_equal({ "feature" => "bill_setup", "call_id" => @call.call_id, "correlation_id" => "rule_run:42",
                   "family_id" => @family.id.to_s, "endpoint" => "test", "model" => "test-model" },
                 usage[:workflow_metadata].transform_keys(&:to_s))
  end

  test "the context is fiber storage, so threads started inside a call inherit it" do
    seen = with_ai_call_context(feature: :chat, model: @model) do |call|
      [ call.call_id, Thread.new { Ai::CallContext.current&.call_id }.value ]
    end

    assert_equal seen.first, seen.last
    assert_nil Ai::CallContext.current
  end

  test "a request that would start after the attempt's budget raises Timeout and isn't sent" do
    error = assert_raises(Ai::Error::Timeout) do
      with_ai_call_context(model: @model, budget: 0) do
        Ai::Transport.for(@model.endpoint).send(:probe_chat, @model)
      end
    end

    assert_match(/time budget/, error.message)
    assert_not_requested :post, "https://llm.example.test/v1/chat/completions"
  end

  test "a retry whose wait would outlast the attempt's budget isn't made" do
    model = ai_model(name: "test-model", endpoint: ai_endpoint(name: "test", base_url: "https://llm.example.test/v1", max_retries: 3))
    transport = Ai::Transport.for(model.endpoint)
    transport.stubs(:retry_delay).returns(5)
    transport.expects(:sleep).never
    tries = 0

    with_ai_call_context(model:, budget: 2) do
      assert_raises(Ai::Error::Upstream) { transport.send(:attempt) { tries += 1; raise Ai::Error::Upstream, "busy" } }
    end

    assert_equal 1, tries
  end

  test "the instrumenter forwards every event to RubyLLM's own instrumenter" do
    delegate = mock
    delegate.expects(:instrument).with("chat.ruby_llm", { a: 1 }).yields.returns(:done)

    assert_equal :done, Ai::Transport::Instrumenter.new(delegate).instrument("chat.ruby_llm", { a: 1 }) { :ignored }
  end
end
