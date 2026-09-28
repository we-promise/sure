require "test_helper"

class Provider::Openai::ChatStreamParserTest < ActiveSupport::TestCase
  test "parses output_text delta" do
    chunk = Provider::Openai::ChatStreamParser.new(
      { "type" => "response.output_text.delta", "delta" => "Hello" }
    ).parsed

    assert_equal "output_text", chunk.type
    assert_equal "Hello", chunk.data
  end

  test "parses refusal delta as output_text" do
    chunk = Provider::Openai::ChatStreamParser.new(
      { "type" => "response.refusal.delta", "delta" => "I cannot..." }
    ).parsed

    assert_equal "output_text", chunk.type
    assert_equal "I cannot...", chunk.data
  end

  test "returns nil for unknown event types" do
    assert_nil Provider::Openai::ChatStreamParser.new({ "type" => "response.created" }).parsed
    assert_nil Provider::Openai::ChatStreamParser.new({ "type" => "response.in_progress" }).parsed
  end

  test "response.failed produces an error chunk with upstream message and code" do
    chunk = Provider::Openai::ChatStreamParser.new(
      {
        "type" => "response.failed",
        "response" => {
          "error" => { "message" => "Previous response not found", "code" => "previous_response_not_found" }
        }
      }
    ).parsed

    assert_equal "error", chunk.type
    assert_equal "response.failed", chunk.data.event
    assert_equal "Previous response not found", chunk.data.message
    assert_equal "previous_response_not_found", chunk.data.code
  end

  test "response.incomplete produces an error chunk using incomplete_details.reason" do
    chunk = Provider::Openai::ChatStreamParser.new(
      {
        "type" => "response.incomplete",
        "response" => {
          "incomplete_details" => { "reason" => "max_output_tokens" }
        }
      }
    ).parsed

    assert_equal "error", chunk.type
    assert_equal "response.incomplete", chunk.data.event
    assert_equal "max_output_tokens", chunk.data.message
    assert_equal "max_output_tokens", chunk.data.code
  end

  test "response.failed without details still surfaces an event-tagged error" do
    chunk = Provider::Openai::ChatStreamParser.new({ "type" => "response.failed" }).parsed

    assert_equal "error", chunk.type
    assert_equal "response.failed", chunk.data.event
    assert_match(/response\.failed/, chunk.data.message)
  end

  # The Responses API nests the payload under "error" — this is the actual
  # shape captured from a live TPM rate-limit response. Regression test for a
  # bug where `object.dig("message")`/`object.dig("code")` read the top level
  # and always missed it, silently falling back to a generic placeholder that
  # hid the real (and actionable) upstream message from users.
  test "nested error event becomes an error chunk with the upstream message and code" do
    chunk = Provider::Openai::ChatStreamParser.new(
      {
        "type" => "error",
        "error" => {
          "type" => "tokens",
          "code" => "rate_limit_exceeded",
          "message" => "Rate limit reached for gpt-4.1 on tokens per min (TPM): Limit 30000, Used 22496, Requested 15270. Please try again in 15.532s.",
          "param" => nil
        },
        "sequence_number" => 2
      }
    ).parsed

    assert_equal "error", chunk.type
    assert_equal "error", chunk.data.event
    assert_match(/Rate limit reached/, chunk.data.message)
    assert_equal "rate_limit_exceeded", chunk.data.code
  end

  # Some OpenAI-compatible endpoints have been seen sending the error fields
  # flat instead of nested — kept as a fallback so those still surface a
  # message instead of the generic placeholder.
  test "flat top-level error event still becomes an error chunk" do
    chunk = Provider::Openai::ChatStreamParser.new(
      { "type" => "error", "message" => "Rate limit exceeded", "code" => "rate_limit_exceeded" }
    ).parsed

    assert_equal "error", chunk.type
    assert_equal "error", chunk.data.event
    assert_equal "Rate limit exceeded", chunk.data.message
    assert_equal "rate_limit_exceeded", chunk.data.code
  end

  test "error event without any message falls back to a generic placeholder" do
    chunk = Provider::Openai::ChatStreamParser.new({ "type" => "error" }).parsed

    assert_equal "error", chunk.type
    assert_equal "OpenAI stream returned an error event", chunk.data.message
    assert_nil chunk.data.code
  end

  # A non-Hash "error" value must not raise TypeError from Hash#dig — it
  # should fall through to the flat/placeholder fallback like a missing one.
  test "error event with a non-Hash error value falls back instead of raising" do
    chunk = Provider::Openai::ChatStreamParser.new(
      { "type" => "error", "error" => "boom" }
    ).parsed

    assert_equal "error", chunk.type
    assert_equal "OpenAI stream returned an error event", chunk.data.message
    assert_nil chunk.data.code
  end

  test "response.completed parses into a response chunk" do
    chunk = Provider::Openai::ChatStreamParser.new(
      {
        "type" => "response.completed",
        "response" => {
          "id" => "resp_1",
          "model" => "gpt-4.1",
          "output" => [],
          "usage" => { "total_tokens" => 5 }
        }
      }
    ).parsed

    assert_equal "response", chunk.type
    assert_equal "resp_1", chunk.data.id
    assert_equal({ "total_tokens" => 5 }, chunk.usage)
  end
end
