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

  test "top-level error event becomes an error chunk" do
    chunk = Provider::Openai::ChatStreamParser.new(
      { "type" => "error", "message" => "Rate limit exceeded", "code" => "rate_limit_exceeded" }
    ).parsed

    assert_equal "error", chunk.type
    assert_equal "error", chunk.data.event
    assert_equal "Rate limit exceeded", chunk.data.message
    assert_equal "rate_limit_exceeded", chunk.data.code
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
