require "test_helper"

# One contract every transport passes (ai-plumbing-redesign.md, section 17): error mapping,
# retries, usage normalisation, the proxy, and that clients are built only by
# Ai::Transport::Http. 2c adds generate's JSON-mode and bad-output cases, 2d judge, 2e embed.
class AiTransportContractTest < ActiveSupport::TestCase
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  TRANSPORTS = {
    compatible: {
      endpoint: { protocol: :compatible, base_url: "https://llm.example.test/v1" },
      url: "https://llm.example.test/v1/chat/completions",
      ok: { id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ],
            usage: { prompt_tokens: 12_457, completion_tokens: 2, total_tokens: 12_459, prompt_tokens_details: { cached_tokens: 11_945 } } },
      error: ->(message, code = nil) { { error: { message:, type: "invalid_request_error", code: }.compact } }
    },
    anthropic: {
      endpoint: { protocol: :anthropic, base_url: "https://anthropic.example.test" },
      url: "https://anthropic.example.test/v1/messages",
      ok: { id: "m1", type: "message", role: "assistant", model: "test-model", content: [ { type: "text", text: "OK" } ],
            stop_reason: "end_turn", usage: { input_tokens: 512, output_tokens: 2, cache_read_input_tokens: 11_945 } },
      error: ->(message, code = nil) { { type: "error", error: { type: code || "invalid_request_error", message: } } }
    }
  }.freeze

  ERRORS = [
    [ 401, "Invalid API Key", nil, Ai::Error::Unauthorized ],
    [ 402, "Insufficient credits", nil, Ai::Error::NoCredit ],
    [ 403, "Forbidden", nil, Ai::Error::Unauthorized ],
    [ 404, "model 'test-model' not found", nil, Ai::Error::ModelMissing ],
    [ 408, "Request timeout", nil, Ai::Error::Timeout ],
    [ 429, "Rate limit reached", nil, Ai::Error::RateLimited ],
    [ 429, "You exceeded your current quota", "insufficient_quota", Ai::Error::NoCredit ],
    [ 400, "Your credit balance is too low to access the Anthropic API.", nil, Ai::Error::NoCredit ],
    [ 400, "request (287168 tokens) exceeds the available context size (65536 tokens)", nil, Ai::Error::ContextTooLong ],
    [ 400, "This model's maximum context length is 8192 tokens", nil, Ai::Error::ContextTooLong ],
    [ 400, "prompt is too long: 210000 tokens > 200000 maximum", nil, Ai::Error::ContextTooLong ],
    [ 400, "Input is too long for requested model.", nil, Ai::Error::ContextTooLong ],
    [ 400, "Unsupported value: 'temperature'", nil, Ai::Error::Refused ],
    [ 500, "Internal error", nil, Ai::Error::Upstream ],
    [ 503, "Service unavailable", nil, Ai::Error::Upstream ],
    [ 529, "Overloaded", nil, Ai::Error::Upstream ]
  ].freeze

  TRANSPORTS.each do |protocol, spec|
    ERRORS.each do |status, message, code, expected|
      test "#{protocol}: HTTP #{status} #{code || message.truncate(30)} maps to #{expected.name.demodulize}" do
        stub_request(:post, spec[:url]).to_return(status:, headers: JSON_HEADERS, body: spec[:error].call(message, code).to_json)

        error = assert_raises(expected) { probe(protocol, :chat) }
        assert_equal status, error.status
      end
    end

    # No response came back for the first two, so they're Unreachable (section 5.4: a connect
    # timeout marks the server); a server that accepted the request and went quiet is Timeout.
    test "#{protocol}: a refused connection or connect timeout is Unreachable; a read timeout is Timeout" do
      stub_request(:post, spec[:url]).to_raise(Errno::ECONNREFUSED)
      assert_raises(Ai::Error::Unreachable) { probe(protocol, :chat) }

      stub_request(:post, spec[:url]).to_timeout
      assert_raises(Ai::Error::Unreachable) { probe(protocol, :chat) }

      stub_request(:post, spec[:url]).to_raise(Net::ReadTimeout)
      assert_raises(Ai::Error::Timeout) { probe(protocol, :chat) }
    end

    test "#{protocol}: retries follow the endpoint, not RubyLLM's defaults" do
      Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
      stub_request(:post, spec[:url]).to_return(status: 503, headers: JSON_HEADERS, body: spec[:error].call("unavailable").to_json)

      assert_raises(Ai::Error::Upstream) { probe(protocol, :chat) }
      assert_requested :post, spec[:url], times: 1

      WebMock.reset_executed_requests!
      assert_raises(Ai::Error::Upstream) { probe(protocol, :chat, max_retries: 2) }
      assert_requested :post, spec[:url], times: 3
    end

    test "#{protocol}: a spent balance is never retried" do
      Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
      stub_request(:post, spec[:url]).to_return(status: 429, headers: JSON_HEADERS,
                                                body: spec[:error].call("You exceeded your current quota", "insufficient_quota").to_json)

      assert_raises(Ai::Error::NoCredit) { probe(protocol, :chat, max_retries: 3) }
      assert_requested :post, spec[:url], times: 1
    end

    test "#{protocol}: usage comes through RubyLLM's usage event, cached tokens included in the prompt" do
      stub_request(:post, spec[:url]).to_return(status: 200, headers: JSON_HEADERS, body: spec[:ok].to_json)

      usage = capture_ai_events("usage.ruby_llm") { assert_equal "OK", probe(protocol, :chat) }.sole.payload
      tokens = Ai::Tokens.from_ruby_llm(usage[:tokens], usage[:cost])

      assert_equal :succeeded, usage[:status]
      assert_equal 12_457, tokens.prompt_tokens
      assert_equal 11_945, tokens.cache_read_tokens
      assert_equal 2, tokens.output_tokens
    end

    test "#{protocol}: a probe answered by another model is ModelMissing" do
      stub_request(:post, spec[:url]).to_return(status: 200, headers: JSON_HEADERS, body: spec[:ok].merge(model: "loaded-model").to_json)

      assert_raises(Ai::Error::ModelMissing) { probe(protocol, :chat) }
    end

    test "#{protocol}: one probe.ai event per call, with the route and the error class but never the key" do
      stub_request(:post, spec[:url]).to_return(status: 401, headers: JSON_HEADERS, body: spec[:error].call("Invalid key test-secret-value-1").to_json)

      event = capture_ai_events { assert_raises(Ai::Error::Unauthorized) { probe(protocol, :chat) } }.sole

      assert_equal "probe.ai", event.name
      assert_equal({ endpoint: "contract", model: "test-model" }, event.payload[:route])
      assert_equal "Ai::Error::Unauthorized", event.payload[:error]
      assert_not_includes event.payload.to_s, "test-secret-value-1"
    end

    test "#{protocol}: requests go through the resolved proxy" do
      stub_request(:post, spec[:url]).to_return(status: 200, headers: JSON_HEADERS, body: spec[:ok].to_json)

      with_env_overrides("HTTPS_PROXY" => "http://proxy.internal:8888", "HTTP_PROXY" => nil) do
        transport = Ai::Transport.for(endpoint(protocol))
        assert_equal "http://proxy.internal:8888", transport.send(:ruby_llm_context).config.http_proxy
      end
    end
  end

  test "only Ai::Transport::Http builds HTTP clients under app/models/ai" do
    offenders = Dir[Rails.root.join("app/models/ai/**/*.rb")].reject { _1.end_with?("ai/transport/http.rb") }.select do |path|
      File.read(path).match?(/(OpenAI::Client|Anthropic::Client|Faraday)\.new\b/)
    end

    assert_empty offenders.map { Pathname(_1).relative_path_from(Rails.root).to_s },
                 "Build clients in app/models/ai/transport/http.rb, so every client gets the timeout, headers, TLS settings and proxy"
  end

  # RubyLLM hides internal helpers from its documented API between releases (#1438). These are
  # the public methods Sure relies on; an upgrade that drops one fails here, not in production.
  test "the RubyLLM surface Sure uses is still public" do
    { RubyLLM => %i[context workflow with_usage_owner render_prompt], RubyLLM::OpenTelemetry => %i[enable] }.each do |owner, methods|
      methods.each { assert owner.respond_to?(_1), "RubyLLM.#{_1}" }
    end
    { RubyLLM::Context => %i[chat embed judge],
      RubyLLM::Judgment => %i[answers tokens model []], RubyLLM::Choice => %i[choice probabilities confidence to_h],
      RubyLLM::Chat => %i[generate add_message with_headers with_max_output_tokens with_tools with_instructions with_schema
                          with_thinking with_provider_options],
      RubyLLM::Message => %i[content model tokens cost tool_calls finish_reason raw], RubyLLM::Embedding => %i[vectors],
      RubyLLM::Tokens => %i[input output cache_read cache_write reported_cost],
      RubyLLM::Attachment => %i[filename mime_type resolution] }.each do |klass, methods|
      methods.each { assert klass.public_method_defined?(_1), "#{klass}##{_1}" }
    end
    assert_includes RubyLLM::Attachment::RESOLUTIONS, :high
    assert_kind_of RubyLLM::Error, RubyLLM::PaymentRequiredError.new
    assert_includes RubyLLM::Configuration.instance_methods, :typesafe_api_base=
    assert_includes RubyLLM::Configuration.instance_methods, :typesafe_api_key=
  end

  private
    def endpoint(protocol, **attributes)
      ai_endpoint(name: "contract", api_key: "test-secret-value-1", **TRANSPORTS.fetch(protocol)[:endpoint], **attributes)
    end

    def probe(protocol, check, **endpoint_attributes)
      model_endpoint = endpoint(protocol, **endpoint_attributes)
      Ai::Transport.for(model_endpoint).probe(ai_model(endpoint: model_endpoint), check)
    end
end
