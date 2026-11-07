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
    assert_in_delta 0.00114, succeeded.estimated_cost, 1e-9, "RubyLLM's price for the model, cache reads at the cached rate"
  end

  test "without RubyLLM's price, the published table prices cached input as input, except Anthropic's" do
    subscriber = Ai::Instrumentation::UsageSubscriber.new
    tokens = Ai::Tokens.new(input_tokens: 200, cache_read_tokens: 1_000, output_tokens: 30)

    assert_in_delta LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1_200, completion_tokens: 30),
                    subscriber.send(:cost, tokens, "gpt-4.1"), 1e-9
    assert_in_delta LlmUsage.calculate_cost(model: "claude-opus-5-5", prompt_tokens: 200, completion_tokens: 30, cache_read_tokens: 1_000),
                    subscriber.send(:cost, tokens, "claude-opus-5-5"), 1e-9
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

  test "each failed retry keeps its own error, even when a later retry succeeds" do
    stub_request(:post, URL).to_return({ status: 503, body: { error: { message: "busy" } }.to_json, headers: json },
                                       { status: 429, body: { error: { message: "slow down" } }.to_json, headers: json },
                                       { status: 200, body: OK.to_json, headers: json })

    rows = @family.llm_usages.where(call_id: run_call(feature: :bill_setup)).order(:created_at)

    assert_equal %w[failed failed succeeded], rows.map(&:status)
    assert_equal [ [ "Ai::Error::Upstream", 503 ], [ "Ai::Error::RateLimited", 429 ] ],
                 rows.first(2).map { [ _1.metadata["error_class"], _1.metadata["http_status_code"] ] }
    assert_match "busy", rows.first.error_message
    assert_match "slow down", rows.second.error_message
    assert_nil rows.last.error_message
  end

  test "a credential in a static header is scrubbed from the error, as the key is" do
    @endpoint = ai_endpoint(name: "gateway", extra_headers: { "X-Tenant-Key" => "tenant-opaque-123" })
    @model = ai_model(name: "gpt-4.1", endpoint: @endpoint)
    @transport = Ai::Transport.for(@endpoint)
    stub_request(:post, URL).to_return(status: 401, body: { error: { message: "unknown tenant tenant-opaque-123" } }.to_json, headers: json)

    error = assert_raises(Ai::Error::Unauthorized) { run_call(feature: :categorize) }

    assert_not_includes error.message, "tenant-opaque-123"
    assert_not_includes LlmUsage.where(family: @family).order(:created_at).last.error_message, "tenant-opaque-123"
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

    # A call as a generation makes it: a call context with the family, the transport's
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
