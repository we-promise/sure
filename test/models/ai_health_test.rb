require "test_helper"

class AiHealthTest < ActiveSupport::TestCase
  AI_ENVIRONMENT = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL
    ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY VECTOR_STORE_PROVIDER
    OPENAI_SUPPORTS_RESPONSES_ENDPOINT
  ].index_with(nil).freeze

  setup do
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    Setting.stubs(:anthropic_access_token).returns(nil)
  end

  test "native OpenAI remains distinct from OpenAI-compatible providers" do
    with_openai_endpoint(nil) do |health|
      assert_equal :openai, health.selected_llm_provider
      assert_equal :openai, health.effective_llm_provider
      assert_not health.openai_compatible_endpoint?
    end
  end

  test "identifies known OpenAI-compatible providers from their endpoints" do
    {
      "http://ollama:11434/v1" => :ollama,
      "http://127.0.0.1:11434/v1" => :ollama,
      "https://openrouter.ai/api/v1" => :openrouter,
      "https://api.together.ai/v1" => :together,
      "https://api.kilo.ai/api/gateway" => :kilo,
      "https://api.cloudflare.com/client/v4/accounts/account-id/ai/v1" => :cloudflare,
      "https://gateway.ai.cloudflare.com/v1/account-id/gateway-id/compat" => :cloudflare,
      "https://models.example.test/v1" => :custom_openai_compatible
    }.each do |endpoint, provider|
      with_openai_endpoint(endpoint) do |health|
        assert_equal :openai_compatible, health.selected_llm_provider, endpoint
        assert_equal provider, health.effective_llm_provider, endpoint
        assert health.openai_compatible_endpoint?, endpoint
        assert_not health.llm_fallback?, endpoint
      end
    end
  end

  test "a confirmed tools refusal reads as missing function-calling support" do
    health = probed_health(llm: :passing, function_calling: failing_result(:tools_refused, http_status: 404))

    assert_equal :unsupported, health.function_calling_status
  end

  test "a service that fell over is not read as a model without function calling" do
    [
      failing_result(:request_failed, http_status: 422),
      failing_result(:request_failed, http_status: 429),
      failing_result(:request_failed, http_status: 500),
      failing_result(:request_failed),
      failing_result(:invalid_response),
      failing_result(:timeout)
    ].each do |probe_result|
      health = probed_health(llm: :passing, function_calling: probe_result)

      assert_equal :failing, health.function_calling_status,
        "#{probe_result.failure_code} #{probe_result.http_status} should not blame the model"
    end
  end

  test "a model that answers without calling the tool is reported separately" do
    health = probed_health(llm: :passing, function_calling: failing_result(:no_tool_call))

    assert_equal :not_used, health.function_calling_status
  end

  test "a refusal still reads as unsupported when the plain LLM check is failing too" do
    health = probed_health(llm: :failing, function_calling: failing_result(:tools_refused))

    assert_equal :unsupported, health.function_calling_status
  end

  test "function calling is probed through the API the assistant would use" do
    {
      { "OPENAI_URI_BASE" => nil } => true,
      { "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1" } => false,
      { "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1", "OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => "true" } => true,
      { "OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => "false" } => false
    }.each do |environment, use_responses_endpoint|
      AiHealth::Probe.any_instance.stubs(:llm).returns(result(:passing))
      AiHealth::Probe.any_instance.stubs(:pdf_text_extraction).returns(result(:passing))
      AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(result(:passing))
      AiHealth::Probe.any_instance.expects(:function_calling)
                     .with(has_entry(use_responses_endpoint: use_responses_endpoint))
                     .returns(result(:passing))

      ClimateControl.modify(
        AI_ENVIRONMENT.merge(
          "OPENAI_ACCESS_TOKEN" => "test-token",
          "OPENAI_MODEL" => "test-model"
        ).merge(environment)
      ) { AiHealth.new }
    end
  end

  test "function calling is only checked alongside the other live probes" do
    with_openai_endpoint("https://openrouter.ai/api/v1") do |health|
      assert_equal :not_checked, health.function_calling_status
    end
  end

  private
    def probed_health(llm:, function_calling:)
      AiHealth::Probe.any_instance.stubs(:llm).returns(result(llm))
      AiHealth::Probe.any_instance.stubs(:function_calling).returns(function_calling)
      AiHealth::Probe.any_instance.stubs(:pdf_text_extraction).returns(result(:passing))
      AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(result(:passing))

      ClimateControl.modify(
        AI_ENVIRONMENT.merge(
          "OPENAI_ACCESS_TOKEN" => "test-token",
          "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1",
          "OPENAI_MODEL" => "test-model"
        )
      ) { AiHealth.new }
    end

    def result(status)
      AiHealth::Probe::Result.new(
        status: status,
        checked_at: Time.current,
        failure_code: nil,
        http_status: nil
      )
    end

    def failing_result(failure_code, http_status: nil)
      AiHealth::Probe::Result.new(
        status: :failing,
        checked_at: Time.current,
        failure_code: failure_code,
        http_status: http_status
      )
    end

    def with_openai_endpoint(endpoint)
      ClimateControl.modify(
        AI_ENVIRONMENT.merge(
          "OPENAI_ACCESS_TOKEN" => "test-token",
          "OPENAI_URI_BASE" => endpoint,
          "OPENAI_MODEL" => endpoint.present? ? "test-model" : nil,
          "VECTOR_STORE_PROVIDER" => "qdrant"
        )
      ) do
        yield AiHealth.new(run_probes: false)
      end
    end
end
