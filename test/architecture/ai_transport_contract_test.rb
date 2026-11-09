require "test_helper"

# One contract every transport passes: error mapping, retries, usage normalisation, the
# proxy, and that clients are built only by Ai::Transport::Http.
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

    # No response came back for the first two, so they're Unreachable (a connect timeout
    # marks the server down); a server that accepted the request and went quiet is Timeout.
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

    test "#{protocol}: a dated snapshot of the model passes the probe; a sibling model doesn't" do
      { "test-model-2025-04-14" => true, "vendor/test-model-20250929" => true, "test-model-mini" => false, "test-model2" => false,
        "test-model-o" => false }.each do |answered, same|
        stub_request(:post, spec[:url]).to_return(status: 200, headers: JSON_HEADERS, body: spec[:ok].merge(model: answered).to_json)

        if same
          assert_equal "OK", probe(protocol, :chat), answered
        else
          assert_raises(Ai::Error::ModelMissing, answered) { probe(protocol, :chat) }
        end
      end
    end

    test "#{protocol}: a tool probe answered by another model is ModelMissing" do
      stub_request(:post, spec[:url]).to_return(status: 200, headers: JSON_HEADERS, body: spec[:ok].merge(model: "loaded-model").to_json)

      assert_raises(Ai::Error::ModelMissing) { probe(protocol, :tools) }
    end

    test "#{protocol}: a probe's own timeout applies to its RubyLLM requests" do
      transport = Ai::Transport.for(endpoint(protocol, timeout_seconds: 60))

      assert_equal 1, transport.send(:ruby_llm_context, timeout: 1).config.request_timeout
      assert_equal 60, transport.send(:ruby_llm_context).config.request_timeout
    end

    test "#{protocol}: RubyLLM's requests get Sure's TLS settings" do
      Ai::Transport::Http.stubs(:faraday_ssl_options).returns(verify: false)
      adapter = Ai::Transport.for(endpoint(protocol)).send(:ruby_llm_context).config.faraday_adapter
      env = Faraday::Env.from(url: URI("https://self-hosted.example.test/v1"), request: Faraday::RequestOptions.new, ssl: Faraday::SSLOptions.new)

      http = adapter.new.build_connection(env)

      assert_equal OpenSSL::SSL::VERIFY_NONE, http.verify_mode
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

      with_env_overrides("HTTPS_PROXY" => "http://proxy.internal:8888", "HTTP_PROXY" => nil, "NO_PROXY" => nil, "no_proxy" => nil) do
        transport = Ai::Transport.for(endpoint(protocol))
        assert_equal "http://proxy.internal:8888", transport.send(:ruby_llm_context).config.http_proxy
        # The proxy RubyLLM's own Faraday connection uses (Provider#connection is :nodoc:, read here only).
        chat = transport.send(:ruby_llm_chat, ai_model(endpoint: endpoint(protocol)))
        assert_equal "http://proxy.internal:8888", chat.instance_variable_get(:@provider).connection.connection.proxy.uri.to_s

        host = URI(spec[:url]).host
        with_env_overrides("NO_PROXY" => host) do
          assert_nil Ai::Transport.for(endpoint(protocol)).send(:ruby_llm_context).config.http_proxy, "NO_PROXY goes direct"
        end
      end
    end
  end

  # Faraday's own ENV lookup drops the port before matching NO_PROXY, so it would proxy a
  # request Sure's resolver sends direct. RubyLLM's adapter applies Sure's decision instead.
  test "RubyLLM's adapter connects as Sure's proxy resolver decides, port-qualified NO_PROXY included" do
    with_env_overrides("HTTP_PROXY" => "http://proxy.internal:8888", "HTTPS_PROXY" => nil, "NO_PROXY" => "10.0.0.5:8080") do
      adapter = Ai::Transport::Http::TlsNetHttp.new(->(_env) { })
      connect = ->(url) { adapter.send(:build_connection, Faraday::Env.from(url: URI(url), request: Faraday::RequestOptions.new)) }

      assert_not connect.("http://10.0.0.5:8080/v1/chat/completions").proxy?, "NO_PROXY's host:port goes direct"
      proxied = connect.("http://10.0.0.6:8080/v1/chat/completions")
      assert_equal [ "proxy.internal", 8888 ], [ proxied.proxy_address, proxied.proxy_port ]
      assert_not connect.("http://127.0.0.1:8080/v1/chat/completions").proxy?, "loopback goes direct"
    end
  end

  test "an OpenRouter endpoint without a URL resolves its proxy against OpenRouter" do
    model_endpoint = ai_endpoint(name: "router", preset: :openrouter, base_url: nil, api_key: "k")
    with_env_overrides("HTTPS_PROXY" => "http://proxy.internal:8888", "HTTP_PROXY" => nil, "NO_PROXY" => "openrouter.ai") do
      transport = Ai::Transport.for(model_endpoint)

      assert_equal "https://openrouter.ai/api/v1", transport.send(:ruby_llm_api_base)
      assert_nil transport.send(:ruby_llm_context).config.http_proxy
    end
  end

  test "two qualified ids are the same model only within one namespace" do
    transport = Ai::Transport.for(ai_endpoint(name: "gw", base_url: "https://llm.example.test/v1"))

    assert transport.send(:same_model?, "org-a/model-x", "org-a/model-x-2025-04-14")
    assert_not transport.send(:same_model?, "org-a/model-x", "org-b/model-x")
    assert transport.send(:same_model?, "model-x", "org-b/model-x")
  end

  test "two different names of the same length are different models" do
    transport = Ai::Transport.for(ai_endpoint(name: "gw", base_url: "https://llm.example.test/v1"))

    assert_not transport.send(:same_model?, "gpt-4o", "gpt-41")
    assert_not transport.send(:same_model?, "test-model", "loaded-mod")
  end

  test "anthropic: a chat probe for a model the API doesn't have is ModelMissing" do
    stub_request(:post, TRANSPORTS[:anthropic][:url]).to_return(
      status: 404, headers: JSON_HEADERS, body: TRANSPORTS[:anthropic][:error].("model: test-model", "not_found_error").to_json
    )

    assert_raises(Ai::Error::ModelMissing) { probe(:anthropic, :chat) }
    assert_raises(Ai::Error::ModelMissing) { probe(:anthropic, :tools) }
  end

  test "a chat answer that isn't the API's shape, such as an HTML page with a 200, is InvalidOutput" do
    stub_request(:post, TRANSPORTS[:compatible][:url]).to_return(status: 200, headers: { "Content-Type" => "text/html" }, body: "<html>login</html>")

    assert_raises(Ai::Error::InvalidOutput) { probe(:compatible, :chat) }
  end

  test "an embedding endpoint with static headers is refused, since RubyLLM 2.1.1 can't send them" do
    model_endpoint = ai_endpoint(name: "embed", base_url: "https://llm.example.test/v1", extra_headers: { "X-Gateway-Key" => "k" })

    assert_raises(Ai::Error::Refused) { Ai::Transport.for(model_endpoint).probe(ai_model(endpoint: model_endpoint), :embedding) }
    assert_not_requested :post, "https://llm.example.test/v1/embeddings"
  end

  test "an embedding response that isn't the expected shape is InvalidOutput" do
    model_endpoint = ai_endpoint(name: "embed", base_url: "https://llm.example.test/v1")
    stub_request(:post, "https://llm.example.test/v1/embeddings").to_return(status: 200, headers: JSON_HEADERS, body: "{}")

    assert_raises(Ai::Error::InvalidOutput) { Ai::Transport.for(model_endpoint).probe(ai_model(endpoint: model_endpoint), :embedding) }
  end

  test "a models list with an entry that isn't an object is InvalidOutput" do
    Ai::Transport::Http.stubs(:openai_client).returns(stub(models: stub(list: { "data" => [ nil ] })))
    model_endpoint = ai_endpoint(name: "listing", base_url: "https://llm.example.test/v1")

    assert_raises(Ai::Error::InvalidOutput) { Ai::Transport.for(model_endpoint).probe(ai_model(endpoint: model_endpoint), :models) }
  end

  test "only Ai::Transport::Http builds HTTP clients under app/models/ai" do
    offenders = Dir[Rails.root.join("app/models/ai/**/*.rb")].reject { _1.end_with?("ai/transport/http.rb") }.select do |path|
      File.read(path).match?(/(OpenAI::Client|Anthropic::Client|Faraday)\.new\b/)
    end

    assert_empty offenders.map { Pathname(_1).relative_path_from(Rails.root).to_s },
                 "Build clients in app/models/ai/transport/http.rb, so every client gets the timeout, headers, TLS settings and proxy"
  end

  # RubyLLM hides internal helpers from its documented API between releases (RubyLLM #1438). These are
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
      RubyLLM::Tokens => %i[input output cache_read cache_write reported_cost] }.each do |klass, methods|
      methods.each { assert klass.public_method_defined?(_1), "#{klass}##{_1}" }
    end
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
