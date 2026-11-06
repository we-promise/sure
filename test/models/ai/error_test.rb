require "test_helper"

class Ai::ErrorTest < ActiveSupport::TestCase
  test "statuses map onto the taxonomy" do
    {
      401 => Ai::Error::Unauthorized, 403 => Ai::Error::Unauthorized, 402 => Ai::Error::NoCredit,
      404 => Ai::Error::Refused, 408 => Ai::Error::Timeout, 429 => Ai::Error::RateLimited,
      400 => Ai::Error::Refused, 422 => Ai::Error::Refused, 500 => Ai::Error::Upstream,
      503 => Ai::Error::Upstream, 529 => Ai::Error::Upstream
    }.each do |status, klass|
      assert_equal klass, Ai::Error.for_status(status, "something"), "HTTP #{status}"
    end
  end

  test "each provider's context-length wording is ContextTooLong" do
    [
      "This model's maximum context length is 8192 tokens",                         # OpenAI, vLLM
      "request (287168 tokens) exceeds the available context size (65536 tokens)",  # llama.cpp
      "prompt is too long: 210000 tokens > 200000 maximum",                         # Anthropic
      "Input is too long for requested model.",                                     # Bedrock
      "Engine protocol predict request returned 400: context length exceeded"       # LM Studio
    ].each do |message|
      assert_equal Ai::Error::ContextTooLong, Ai::Error.for_status(400, message), message
    end
  end

  test "a spent balance is NoCredit, however the provider says it" do
    assert_equal Ai::Error::NoCredit, Ai::Error.for_status(400, "Your credit balance is too low to access the Anthropic API")
    assert_equal Ai::Error::NoCredit, Ai::Error.for_status(429, "You exceeded your current quota", body: { "error" => { "code" => "insufficient_quota" } })
    assert_equal Ai::Error::NoCredit, Ai::Error.for_status(429, "You have no credits remaining.", body: { "error" => { "code" => "credit_balance_exhausted" } })
    assert_equal Ai::Error::NoCredit, Ai::Error.for_status(402, "Insufficient credits")
    assert_equal Ai::Error::RateLimited, Ai::Error.for_status(429, "Rate limit reached for requests")
  end

  test "a 404 naming the model is ModelMissing; any other 404 is Refused" do
    assert_equal Ai::Error::ModelMissing, Ai::Error.for_status(404, "model 'qwen3:8b' not found")
    assert_equal Ai::Error::ModelMissing, Ai::Error.for_status(404, "The model `gpt-9` does not exist or you do not have access to it.")
    assert_equal Ai::Error::ModelMissing, Ai::Error.for_status(404, "x", body: { "error" => { "code" => "model_not_found" } })
    assert_equal Ai::Error::Refused, Ai::Error.for_status(404, "Not Found")
  end

  test "from_status keeps the status" do
    error = Ai::Error.from_status(503, "overloaded")

    assert_instance_of Ai::Error::Upstream, error
    assert_equal 503, error.status
  end

  test "from_exception maps network failures and HTTP errors from client gems" do
    assert_instance_of Ai::Error::Timeout, Ai::Error.from_exception(Faraday::TimeoutError.new("slow"))
    assert_instance_of Ai::Error::Timeout, Ai::Error.from_exception(Net::ReadTimeout.new)
    assert_instance_of Ai::Error::Unreachable, Ai::Error.from_exception(Faraday::ConnectionFailed.new("refused"))
    assert_instance_of Ai::Error::Unreachable, Ai::Error.from_exception(Errno::ECONNREFUSED.new)

    ruby_openai = Faraday::UnauthorizedError.new("401", { status: 401, body: { "error" => "bad key" } })
    assert_instance_of Ai::Error::Unauthorized, Ai::Error.from_exception(ruby_openai)

    assert_nil Ai::Error.from_exception(RuntimeError.new("ours"))
  end

  test "Unavailable carries its reason" do
    error = Ai::Error::Unavailable.new(:not_configured)

    assert_equal :not_configured, error.reason
    assert_equal "AI unavailable: not_configured", error.message
  end

  test "only rate limits, 5xx and timeouts are retried by a transport" do
    assert_equal [ Ai::Error::RateLimited, Ai::Error::Upstream, Ai::Error::Timeout ], Ai::Error::RETRYABLE
  end
end
