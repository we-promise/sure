require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "manifest responds successfully for html accept headers" do
    get "/manifest", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/manifest+json", response.media_type
    assert_includes response.body, '"start_url": "/"'
  end

  test "service worker responds successfully for browser service worker requests" do
    get "/service-worker", headers: {
      "Accept" => "*/*",
      "Sec-Fetch-Dest" => "serviceworker",
      "Sec-Fetch-Mode" => "same-origin",
      "Service-Worker" => "script"
    }

    assert_response :success
    assert_equal "application/javascript", response.media_type
  end
end
