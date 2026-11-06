require "test_helper"

class Ai::Instrumentation::UsageSubscriberTest < ActiveSupport::TestCase
  URL = "https://llm.example.test/v1/chat/completions".freeze
  OK = { id: "c1", model: "gpt-4.1-2025-04-14", choices: [ { index: 0, message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ],
         usage: { prompt_tokens: 1_200, completion_tokens: 30, total_tokens: 1_230, prompt_tokens_details: { cached_tokens: 1_000 } } }.freeze

  setup do
    @family = families(:dylan_family)
    @endpoint = ai_endpoint(name: "openai", max_retries: 2)
    @model = ai_model(name: "gpt-4.1", endpoint: @endpoint)
    @transport = Ai::Transport.for(@endpoint)
    Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
  end

  test "each request of a call is one row, grouped by the call id" do
    stub_request(:post, URL).to_return({ status: 503, body: { error: { message: "busy" } }.to_json, headers: json },
                                       { status: 200, body: OK.to_json, headers: json })

    call_id = run_call(feature: :bill_setup)

    rows = @family.llm_usages.where(call_id:).order(:created_at)
    assert_equal %w[failed succeeded], rows.map(&:status)
    assert_equal [ "bill_setup" ], rows.map(&:operation).uniq
    assert_equal [ "openai" ], rows.map(&:provider).uniq
    assert_equal [ "gpt-4.1" ], rows.map(&:model).uniq

    succeeded = rows.last
    assert_equal 1_200, succeeded.prompt_tokens, "the prompt counts cached tokens"
    assert_equal 1_000, succeeded.cache_read_tokens
    assert_equal 30, succeeded.completion_tokens
    assert succeeded.estimated_cost.positive?, "priced from the published table when the provider reports no cost"
  end

  test "a failed call's rows get the error class and scrubbed message from its .ai event" do
    stub_request(:post, URL).to_return(status: 401, body: { error: { message: "Invalid key test-key" } }.to_json, headers: json)

    call_id = nil
    assert_raises(Ai::Error::Unauthorized) { call_id = run_call(feature: :categorize) }

    row = @family.llm_usages.find_by!(call_id: LlmUsage.where(family: @family).order(:created_at).last.call_id)
    assert row.failed?
    assert_equal "Ai::Error::Unauthorized", row.metadata["error_class"]
    assert_equal 401, row.metadata["http_status_code"]
    assert_not_includes row.metadata["error"], "test-key"
    assert_nil call_id
  end

  test "requests outside a family's call write nothing: health probes, evals" do
    stub_request(:post, URL).to_return(status: 200, body: OK.to_json, headers: json)

    assert_no_difference -> { LlmUsage.count } do
      @transport.probe(@model, :chat) rescue Ai::Error::ModelMissing
      Ai::CallContext.call(feature: :eval, model: @model) { @transport.send(:probe_chat, @model) } rescue Ai::Error::ModelMissing
    end
  end

  test "a broken row never breaks the call" do
    stub_request(:post, URL).to_return(status: 200, body: OK.to_json, headers: json)
    LlmUsage.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)
    Rails.logger.expects(:error).with(includes("UsageSubscriber")).at_least_once

    assert_nothing_raised { run_call(feature: :bill_setup) }
  end

  private
    def json = { "Content-Type" => "application/json" }

    # A call as 2c's generations will make it: a call context with the family, the transport's
    # retries, one .ai event.
    def run_call(feature:)
      Ai::CallContext.call(feature:, model: @model, family: @family, budget: 30) do |call|
        @transport.send(:instrument, "generate", model: @model, request: {}) do
          @transport.send(:attempt) { @transport.send(:probe_chat, @model) }
        end
        call.call_id
      end
    end
end
