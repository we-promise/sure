# frozen_string_literal: true

require "test_helper"

class Provider::Openai::GenericChatParserTest < ActiveSupport::TestCase
  test "parses regular function calls without extra_content" do
    raw_response = {
      "id" => "chatcmpl-123",
      "model" => "gpt-4.1",
      "choices" => [
        {
          "message" => {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              {
                "id" => "call_abc123",
                "type" => "function",
                "function" => {
                  "name" => "get_accounts",
                  "arguments" => "{}"
                }
              }
            ]
          }
        }
      ]
    }

    parsed = Provider::Openai::GenericChatParser.new(raw_response).parsed

    assert_equal "chatcmpl-123", parsed.id
    assert_equal "gpt-4.1", parsed.model
    assert_empty parsed.messages
    assert_equal 1, parsed.function_requests.size

    request = parsed.function_requests.first
    assert_equal "call_abc123", request.id
    assert_equal "call_abc123", request.call_id
    assert_equal "get_accounts", request.function_name
    assert_equal "{}", request.function_args
    assert_nil request.extra_content
  end

  test "parses function calls with extra_content including thought_signature" do
    extra = { "google" => { "thought_signature" => "sig_encrypted_token_123" } }
    raw_response = {
      "id" => "chatcmpl-gemini-123",
      "model" => "gemini-3.8-flash",
      "choices" => [
        {
          "message" => {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              {
                "id" => "call_gemini_456",
                "type" => "function",
                "function" => {
                  "name" => "get_holdings",
                  "arguments" => '{"account_id":"acc_1"}'
                },
                "extra_content" => extra
              }
            ]
          }
        }
      ]
    }

    parsed = Provider::Openai::GenericChatParser.new(raw_response).parsed

    assert_equal 1, parsed.function_requests.size
    request = parsed.function_requests.first
    assert_equal "call_gemini_456", request.call_id
    assert_equal "get_holdings", request.function_name
    assert_equal extra, request.extra_content
  end
end
