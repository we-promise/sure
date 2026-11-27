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

  test "a RubyLLM request from a thread started inside a call is recorded for the family and the call" do
    call_id = with_ai_call_context(feature: :chat, model: @model, family: @family) do |call|
      Thread.new { Ai::Transport.for(@model.endpoint).send(:probe_chat, @model) }.join
      call.call_id
    end

    row = @family.llm_usages.find_by!(call_id: call_id)
    assert_equal "chat", row.operation
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
end
