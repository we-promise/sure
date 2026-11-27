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

  test "compression sits after Rack::Sendfile, which is in every stack" do
    stack = Rails.application.middleware.map(&:klass)

    assert_equal stack.index(Rack::Sendfile) + 1, stack.index(Rack::Deflater)
  end

  test "binary content and byte ranges are sent as-is" do
    deflater = build_deflater

    pdf = deflater.call(env_accepting_gzip.merge("TEST_STATUS" => 200, "TEST_TYPE" => "application/pdf"))
    assert_nil pdf[1]["content-encoding"]

    range = deflater.call(env_accepting_gzip.merge("TEST_STATUS" => 206, "TEST_TYPE" => "text/css"))
    assert_nil range[1]["content-encoding"]

    css = deflater.call(env_accepting_gzip.merge("TEST_STATUS" => 200, "TEST_TYPE" => "text/css"))
    assert_equal "gzip", css[1]["content-encoding"]
  end

  private
    # The app's own Rack::Deflater configuration around a stub app.
    def build_deflater
      middleware = Rails.application.middleware.find { |m| m.klass == Rack::Deflater }
      app = ->(env) { [ env["TEST_STATUS"], { "content-type" => env["TEST_TYPE"] }, [ "x" * 2_000 ] ] }
      middleware.build(app)
    end

    def env_accepting_gzip
      Rack::MockRequest.env_for("/", "HTTP_ACCEPT_ENCODING" => "gzip")
    end
end
