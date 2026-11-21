require "test_helper"

# What leaves a request body before a cassette is written: inline files, whichever way the
# provider sends them.
class AiCassetteRedactionTest < ActiveSupport::TestCase
  test "an Anthropic inline file loses its bytes, and the rest of the request is kept" do
    body = { model: "claude-haiku-4-5", messages: [ { role: "user", content: [
      { type: "text", text: "Read this statement" },
      { type: "document", source: { type: "base64", media_type: "application/pdf", data: "JVBERi0xLjQK" } }
    ] } ] }.to_json

    redacted = JSON.parse(AiTestHelper.redact_base64_sources(body))

    content = redacted.dig("messages", 0, "content")
    assert_equal "<FILE>", content.last.dig("source", "data")
    assert_equal "application/pdf", content.last.dig("source", "media_type")
    assert_equal "Read this statement", content.first["text"]
  end

  test "a body that isn't JSON is left as it is" do
    assert_equal "not json", AiTestHelper.redact_base64_sources("not json")
  end
end
