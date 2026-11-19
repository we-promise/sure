require "test_helper"

class ResponseCompressionTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "pages are compressed for a client that accepts it" do
    get root_path, headers: { "Accept-Encoding" => "gzip" }

    assert_response :success
    assert_equal "gzip", response.headers["Content-Encoding"]
    assert_includes Zlib.gunzip(response.body), "</html>"
  end

  test "pages are sent as-is to a client that does not" do
    get root_path

    assert_response :success
    assert_nil response.headers["Content-Encoding"]
    assert_includes response.body, "</html>"
  end
end
