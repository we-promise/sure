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

  test "RubyLLM's usage event carries the family, and the call id" do
    usage = capture_ai_events("usage.ruby_llm") do
      with_ai_call_context(feature: :bill_setup, model: @model, family: @family) do |call|
        @call = call
        Ai::Transport.for(@model.endpoint).send(:probe_chat, @model)
      end
    end.sole.payload

    assert_equal @family, usage[:owner]
    assert_equal @call.call_id, usage[:workflow_id]
    assert_equal({ "feature" => "bill_setup", "call_id" => @call.call_id,
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

  test "a RubyLLM request from a thread started inside a call is recorded for the family and the call" do
    call_id = with_ai_call_context(feature: :chat, model: @model, family: @family) do |call|
      Thread.new { Ai::Transport.for(@model.endpoint).send(:probe_chat, @model) }.join
      call.call_id
    end

    row = @family.llm_usages.sole
    assert_equal call_id, row.call_id
    assert_equal "chat", row.operation
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

  test "a request outside RubyLLM, such as the models list, isn't sent once the budget is spent" do
    model = ai_model(name: "test-model")
    Ai::Transport::Http.expects(:openai_client).never

    with_ai_call_context(model:, budget: 0) do
      assert_raises(Ai::Error::Timeout) { Ai::Transport.for(model.endpoint).send(:attempt) { Ai::Transport::Http.openai_client(model.endpoint) } }
    end
  end

  test "each attempt's request timeout is cut to what's left of the budget" do
    model = ai_model(name: "test-model")
    transport = Ai::Transport.for(model.endpoint)

    with_ai_call_context(model:, budget: 0.2) { assert_operator transport.send(:within_budget, 60), :<=, 0.2 }
    assert_equal 60, transport.send(:within_budget, 60)
  end

  test "an answer that arrives after the budget is spent is a Timeout, not a pass" do
    model = ai_model(name: "test-model")
    transport = Ai::Transport.for(model.endpoint)

    with_ai_call_context(model:, budget: 1) do |call|
      error = assert_raises(Ai::Error::Timeout) do
        transport.send(:attempt) { Ai::CallContext.stubs(:now).returns(call.deadline + 0.1); :ok }
      end
      assert_match(/before the answer arrived/, error.message)
    end
  end

  test "an error with no Ai::Error is scrubbed before it goes on the request event" do
    instrumenter = Ai::Transport::Instrumenter.new(nil, map_error: ->(_) { }, scrub: ->(text) { text.gsub("sk-secret", "[REDACTED]") })
    payload = {}

    assert_raises(RuntimeError) { instrumenter.instrument("request.ruby_llm", payload) { raise "failed with sk-secret" } }
    assert_equal({ error: "failed with [REDACTED]", error_class: "RuntimeError" }, payload[:ai_error])
  end

  test "the instrumenter forwards every event to RubyLLM's own instrumenter" do
    delegate = mock
    delegate.expects(:instrument).with("chat.ruby_llm", { a: 1 }).yields.returns(:done)

    assert_equal :done, Ai::Transport::Instrumenter.new(delegate).instrument("chat.ruby_llm", { a: 1 }) { :ignored }
  end
end
