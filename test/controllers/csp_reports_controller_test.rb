require "test_helper"

class CspReportsControllerTest < ActionDispatch::IntegrationTest
  test "accepts a CSP report and returns 204" do
    payload = { "csp-report" => { "violated-directive" => "script-src", "blocked-uri" => "https://evil.example.com/x.js" } }

    post "/csp-violation-report",
      params: payload.to_json,
      headers: { "Content-Type" => "application/csp-report" }

    assert_response :no_content
  end

  test "accepts an empty body and returns 204" do
    post "/csp-violation-report"
    assert_response :no_content
  end

  test "accepts malformed JSON without raising" do
    post "/csp-violation-report",
      params: "not-json",
      headers: { "Content-Type" => "application/csp-report" }

    assert_response :no_content
  end

  test "truncates bodies larger than MAX_BODY_BYTES without raising" do
    # Send a valid-JSON payload whose byte length exceeds MAX_BODY_BYTES. The
    # controller reads at most MAX_BODY_BYTES, producing a truncated (and
    # therefore unparseable) body — must still return 204 and not 500.
    oversized = "A" * (CspReportsController::MAX_BODY_BYTES + 1024)
    payload = { "csp-report" => { "blocked-uri" => oversized } }.to_json

    post "/csp-violation-report",
      params: payload,
      headers: { "Content-Type" => "application/csp-report" }

    assert_response :no_content
  end

  test "accepts invalid-UTF-8 bytes without raising" do
    # A hostile client can send bytes that make String#truncate blow up if we
    # don't scrub. Must still return 204.
    post "/csp-violation-report",
      params: "\xC3\x28".b, # invalid 2-byte UTF-8 sequence
      headers: { "Content-Type" => "application/csp-report" }

    assert_response :no_content
  end
end
