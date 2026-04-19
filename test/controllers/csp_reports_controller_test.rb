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
end
