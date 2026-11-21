require "test_helper"

class Ai::DownMarksTest < ActiveSupport::TestCase
  test "a rejected credential's mark changes with the key or a static header, so a fix isn't skipped" do
    endpoint = ai_endpoint(name: "gateway", api_key: "k1", extra_headers: { "X-Gateway-Key" => "old" })

    original = Ai::DownMarks.key_key(endpoint)

    assert_not_equal original, Ai::DownMarks.key_key(endpoint.with(api_key: "k2"))
    assert_not_equal original, Ai::DownMarks.key_key(endpoint.with(extra_headers: { "X-Gateway-Key" => "new" }))
    assert_equal original, Ai::DownMarks.key_key(endpoint.with(timeout_seconds: 5))
  end
end
