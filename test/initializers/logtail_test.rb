require "test_helper"

class LogtailTest < ActiveSupport::TestCase
  test "HTTP events are not installed in the application middleware stack" do
    refute_includes Rails.application.middleware.map(&:klass), Logtail::Integrations::Rack::HTTPEvents
  end

  test "standard logging keeps request credentials out of logs" do
    assert_safe_request_logging(ActiveSupport::Logger)
  end

  test "structured Logtail logging keeps request credentials out of logs" do
    assert_safe_request_logging(Logtail::Logger)
  end

  private
    def assert_safe_request_logging(logger_class)
      output = StringIO.new
      logger = logger_class.new(output)
      logger.formatter = Logtail::Logger::JSONFormatter.new if logger_class == Logtail::Logger
      logger.level = Logger::INFO
      logger = ActiveSupport::TaggedLogging.new(logger)
      Rails.stubs(:logger).returns(logger)

      request_headers = {
        "HTTP_AUTHORIZATION" => "Bearer synthetic-bearer-secret",
        "HTTP_PROXY_AUTHORIZATION" => "Basic synthetic-proxy-secret",
        "HTTP_COOKIE" => "_sure_session=synthetic-session-secret; session_token=synthetic-token-secret",
        "HTTP_X_API_KEY" => "synthetic-api-secret"
      }
      response_cookie = "session_token=synthetic-response-secret; HttpOnly; Secure"
      endpoint = lambda do |env|
        request_headers.each { |name, value| assert_equal value, env[name] }
        Rails.logger.info "Request endpoint reached"
        [ 200, { "content-type" => "text/plain", "set-cookie" => response_cookie }, [ "OK" ] ]
      end
      # Exercise the logging middleware installed at boot, including any
      # accidentally reinstalled HTTPEvents. Do not rebuild unrelated middleware
      # such as Rack::Attack, which keeps its endpoint in shared class state.
      stack = ActionDispatch::MiddlewareStack.new
      Rails.application.middleware.each do |middleware|
        if middleware.klass == Rails::Rack::Logger || middleware.klass.name.start_with?("Logtail::")
          stack.use(middleware.klass, *middleware.args, &middleware.block)
        end
      end
      app = stack.build(endpoint)
      env = Rack::MockRequest.env_for(
        "https://www.example.com/logging-probe?token=synthetic-query-secret",
        request_headers
      )
      # Rails::Application#call normally supplies this configuration before
      # dispatching into the middleware (including the parameter filters).
      status, headers, body = app.call(Rails.application.env_config.merge(env))
      body.close if body.respond_to?(:close)

      assert_equal 200, status
      assert_includes Array(headers["set-cookie"]), response_cookie
      assert_includes output.string, "Request endpoint reached"
      assert_includes output.string, "Started GET"
      assert_includes output.string, "[FILTERED]"
      refute_match(/synthetic-[a-z-]+secret/, output.string)
      refute_includes output.string, "headers_json"
      refute_includes output.string, "http_request_received"
      refute_includes output.string, "http_response_sent"
    end
end
