# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

class FinecoBrowserLoginRuntimeTest < ActiveSupport::TestCase
  Observer = Fineco::BrowserLoginRuntime::CaptureObserver

  class CaptureFlowDouble
    attr_reader :captured_session, :capture_attempts

    def initialize(capture_enabled: true, state: :awaiting_login)
      @state = state
      @capture_attempts = 0
      @capture_enabled = capture_enabled
    end

    def capture_enabled?
      @capture_enabled
    end

    def active?
      !%i[captured failed rejected expired stopped].include?(@state)
    end

    def cancellation_requested?
      false
    end

    def expired?
      false
    end

    def authorized?
      true
    end

    def begin_capture
      @capture_attempts += 1
      @state = :capturing
      true
    end

    def awaiting_login!
      @state = :awaiting_login if @state == :starting
    end

    def finish_capture(session)
      @captured_session = session
      @state = :captured
    end

    def capture_retryable
      @state = :awaiting_login
    end

    def current_state
      @state
    end
  end

  class CdpConnectionDouble
    attr_reader :commands
    attr_accessor :runtime_evaluation_result

    def initialize
      @commands = []
      @runtime_evaluation_result = {
        "result" => {
          "type" => "object",
          "value" => { "account_index" => "3", "dossier_index" => "7" }
        }
      }
    end

    def command(method, params = {}, timeout: 5, session_id: nil)
      @commands << [ method, params, timeout, session_id ]
      case method
      when "Network.getResponseBody"
        {
          "body" => JSON.generate(
            "info" => { "dossier" => { "blocked" => false } },
            "positions" => { "show" => [] },
            "summary" => { "show" => {}, "total" => {} }
          ),
          "base64Encoded" => false
        }
      when "Network.getCookies"
        {
          "cookies" => [
            { "name" => "gsessionid", "value" => "smoke-session", "domain" => ".finecobank.com", "path" => "/", "secure" => true }
          ]
        }
      when "Runtime.evaluate"
        @runtime_evaluation_result
      end
    end
  end

  test "portfolio capture accepts only the exact read request" do
    assert Observer.portfolio_request?(
      "https://private-api.finecobank.com/v1/private/tol/positions/summary?type=sintesi",
      "GET"
    )
    refute Observer.portfolio_request?(
      "https://private-api.finecobank.com/v1/private/tol/positions/summary?type=sintesi&type=sintesi",
      "GET"
    )
    refute Observer.portfolio_request?(
      "https://private-api.finecobank.com/v1/private/tol/positions/summary?type=sintesi&other=x",
      "GET"
    )
    refute Observer.portfolio_request?(
      "https://private-api.finecobank.com/v1/private/tol/positions/summary?type=other",
      "GET"
    )
    refute Observer.portfolio_request?(
      "https://private-api.finecobank.com/v1/private/tol/positions/summary?type=sintesi",
      "POST"
    )
    refute Observer.portfolio_request?(
      "https://private-api.finecobank.com.evil.example/v1/private/tol/positions/summary?type=sintesi",
      "GET"
    )
  end

  test "account context expression returns only indices for one unambiguous account" do
    response = execute_account_context_expression(
      page_url: "https://finecobank.com/pvt/home",
      payload: {
        "accounts" => [
          { "index" => 12, "number" => 123456789, "dossiers" => [ { "index" => 4, "number" => 987654321 } ] }
        ]
      }
    )

    assert_equal({ "account_index" => "12", "dossier_index" => "4" }, response.fetch("value"))
    assert_equal 1, response.fetch("fetch_calls")

    ambiguous = execute_account_context_expression(
      page_url: "https://finecobank.com/pvt/home",
      payload: {
        "accounts" => [
          { "index" => 12, "dossiers" => [ { "index" => 4 } ] },
          { "index" => 13, "dossiers" => [ { "index" => 5 } ] }
        ]
      }
    )

    assert_nil ambiguous.fetch("value")
    assert_equal 1, ambiguous.fetch("fetch_calls")

    untrusted = execute_account_context_expression(
      page_url: "https://finecobank.com.evil.example/pvt/home",
      payload: { "accounts" => [ { "index" => 12, "dossiers" => [ { "index" => 4 } ] } ] }
    )

    assert_nil untrusted.fetch("value")
    assert_equal 0, untrusted.fetch("fetch_calls")
  end

  test "automatic discovery waits for the main private page context and login readiness" do
    flow = CaptureFlowDouble.new(state: :starting)
    connection = CdpConnectionDouble.new
    observer = Observer.new(flow)
    observer.instance_variable_set(:@connection, connection)
    observer.instance_variable_set(
      :@page_sessions,
      {
        "page-session" => {
          main_frame_id: nil,
          private_page: false,
          dom_content_ready: false,
          execution_context_id: nil
        }
      }
    )

    observer.send(
      :process_event,
      {
        "method" => "Page.frameNavigated",
        "sessionId" => "page-session",
        "params" => { "frame" => { "id" => "main-frame", "url" => "https://finecobank.com/pvt/home" } }
      }
    )
    observer.send(
      :process_event,
      {
        "method" => "Runtime.executionContextCreated",
        "sessionId" => "page-session",
        "params" => {
          "context" => {
            "id" => 14,
            "auxData" => { "isDefault" => true, "frameId" => "main-frame" }
          }
        }
      }
    )

    assert_empty connection.commands
    assert_equal 0, flow.capture_attempts

    flow.awaiting_login!
    observer.send(:discover_ready_pages)
    assert_empty connection.commands
    observer.send(
      :process_event,
      { "method" => "Page.domContentEventFired", "sessionId" => "page-session", "params" => {} }
    )

    assert_equal [ "Runtime.evaluate", "Network.getCookies" ], connection.commands.map(&:first)
    assert_equal 14, connection.commands.first.fetch(1).fetch("contextId")
    assert_equal "3", flow.captured_session.fetch(:account_index)
    assert_equal "7", flow.captured_session.fetch(:dossier_index)
    assert_equal 1, flow.capture_attempts
  end

  test "automatic discovery page check accepts only Fineco HTTPS private routes" do
    assert Observer.private_page_url?("https://finecobank.com/pvt/home")
    assert Observer.private_page_url?("https://finecobank.com/pvt")
    refute Observer.private_page_url?("https://finecobank.com.evil.example/pvt/home")
    refute Observer.private_page_url?("https://finecobank.com/pvtish/home")
    refute Observer.private_page_url?("http://finecobank.com/pvt/home")
    refute Observer.private_page_url?("https://user@finecobank.com/pvt/home")
  end

  test "automatic account context discovery has one request budget per flow" do
    flow = CaptureFlowDouble.new
    connection = CdpConnectionDouble.new
    connection.runtime_evaluation_result = { "result" => { "type" => "object", "subtype" => "null" } }
    observer = Observer.new(flow)
    observer.instance_variable_set(:@connection, connection)
    observer.instance_variable_set(
      :@page_sessions,
      {
        "page-session" => {
          main_frame_id: "main-frame",
          private_page: true,
          dom_content_ready: true,
          execution_context_id: 14
        }
      }
    )

    observer.send(:discover_ready_pages)
    observer.send(
      :process_event,
      {
        "method" => "Page.navigatedWithinDocument",
        "sessionId" => "page-session",
        "params" => { "frameId" => "main-frame", "url" => "https://finecobank.com/pvt/portfolio" }
      }
    )
    observer.send(:discover_ready_pages)

    assert_equal 1, connection.commands.count { |command| command.first == "Runtime.evaluate" }
    assert_equal 0, flow.capture_attempts
  end

  test "portfolio capture requires one valid selected account and dossier index" do
    assert_equal(
      { account_index: "12", dossier_index: "4" },
      Observer.request_indices("X-Account-Index" => "12", "x-dossier-index" => "4")
    )
    assert_nil Observer.request_indices("x-account-index" => "0", "x-dossier-index" => "1", "X-DOSSIER-INDEX" => "2")
    assert_nil Observer.request_indices("x-account-index" => "1000000", "x-dossier-index" => "1")
    assert_nil Observer.request_indices("x-account-index" => "1", "x-dossier-index" => "../2")
  end

  test "portfolio capture checks the bank response shape without retaining it" do
    payload = {
      "info" => { "dossier" => { "blocked" => false } },
      "positions" => { "show" => [ { "symbol" => "EXAMPLE" } ] },
      "summary" => { "show" => {}, "total" => {} }
    }

    assert Observer.portfolio_schema?(payload)
    refute Observer.portfolio_schema?(payload.deep_merge("info" => { "dossier" => { "blocked" => true } }))
    refute Observer.portfolio_schema?(payload.merge("summary" => { "show" => {} }))
  end

  test "portfolio response body is read only after network loading finishes" do
    flow = CaptureFlowDouble.new
    connection = CdpConnectionDouble.new
    observer = Observer.new(flow)
    observer.instance_variable_set(:@connection, connection)
    observer.instance_variable_set(:@page_sessions, { "page-session" => "target" })
    observer.send(
      :record_request,
      "page-session",
      {
        "requestId" => "request-1",
        "request" => {
          "url" => Observer::PORTFOLIO_URL,
          "method" => "GET",
          "headers" => { "x-account-index" => "3", "x-dossier-index" => "7" }
        }
      }
    )
    observer.send(
      :mark_response_received,
      "page-session",
      {
        "requestId" => "request-1",
        "type" => "XHR",
        "response" => { "status" => 200, "headers" => {} }
      }
    )

    assert_empty connection.commands
    assert_equal 0, flow.capture_attempts
    assert_nil flow.captured_session

    observer.send(:capture_completed_request, "page-session", "requestId" => "request-1")

    assert_equal [ "Network.getResponseBody", "Network.getCookies" ], connection.commands.map(&:first)
    assert_equal "3", flow.captured_session.fetch(:account_index)
    assert_equal "7", flow.captured_session.fetch(:dossier_index)
    assert_equal "smoke-session", flow.captured_session.fetch(:gsessionid)
    assert_equal 1, flow.capture_attempts
  end

  test "diagnostic mode ignores portfolio events without enabling capture" do
    flow = CaptureFlowDouble.new(capture_enabled: false)
    connection = CdpConnectionDouble.new
    observer = Observer.new(flow)
    observer.instance_variable_set(:@connection, connection)
    observer.instance_variable_set(:@page_sessions, { "page-session" => "target" })
    observer.send(
      :record_request,
      "page-session",
      {
        "requestId" => "request-1",
        "request" => {
          "url" => Observer::PORTFOLIO_URL,
          "method" => "GET",
          "headers" => { "x-account-index" => "3", "x-dossier-index" => "7" }
        }
      }
    )
    observer.send(
      :mark_response_received,
      "page-session",
      {
        "requestId" => "request-1",
        "type" => "XHR",
        "response" => { "status" => 200, "headers" => {} }
      }
    )
    observer.send(:capture_completed_request, "page-session", "requestId" => "request-1")

    assert_empty connection.commands
    assert_equal 0, flow.capture_attempts
    assert_nil flow.captured_session
  end

  test "cookie selection returns only a valid matching gsessionid" do
    cookies = [
      { "name" => "LBM", "value" => "load-balancer", "domain" => ".finecobank.com", "path" => "/", "secure" => true },
      { "name" => "gsessionid", "value" => "a-session-value", "domain" => ".finecobank.com", "path" => "/", "secure" => true },
      { "name" => "gsessionid", "value" => "wrong-domain", "domain" => "evilfinecobank.com", "path" => "/", "secure" => true },
      { "name" => "gsessionid", "value" => "wrong-path", "domain" => ".finecobank.com", "path" => "/private/other", "secure" => true }
    ]

    assert_equal "a-session-value", Observer.gsessionid(cookies)
    assert_nil Observer.gsessionid(cookies.select { |cookie| cookie["name"] != "gsessionid" })
    assert_nil Observer.gsessionid(cookies + [ cookies[1].merge("value" => "another-session-value") ])
  end

  test "runtime fails closed unless explicitly enabled with one Puma worker" do
    with_env_overrides("FINECO_BROWSER_ENABLED" => "false", "WEB_CONCURRENCY" => "1") do
      refute Fineco::BrowserLoginRuntime.runtime_configuration_available?
    end
    with_env_overrides("FINECO_BROWSER_ENABLED" => "true", "WEB_CONCURRENCY" => "2") do
      refute Fineco::BrowserLoginRuntime.runtime_configuration_available?
    end
    with_env_overrides("FINECO_BROWSER_ENABLED" => "true", "WEB_CONCURRENCY" => "1") do
      assert Fineco::BrowserLoginRuntime.runtime_configuration_available?
    end
  end

  test "capture callback outcome is terminal and status exposes only safe flow data" do
    identity = { family_id: "family-1", user_id: "user-2", session_id: "session-3" }.freeze
    callback_arguments = nil
    Dir.mktmpdir("fineco-runtime-lock-") do |directory|
      runtime_lock = File.open(File.join(directory, "runtime.lock"), File::RDWR | File::CREAT, 0o600)
      runtime_lock.flock(File::LOCK_EX | File::LOCK_NB)
      flow = Fineco::BrowserLoginRuntime::Flow.new(
        id: "a" * 32,
        identity: identity,
        on_capture: ->(**arguments) { callback_arguments = arguments; true },
        authorized: ->(candidate) { candidate == identity },
        capture_enabled: true,
        runtime_lock: runtime_lock
      )
      flow.awaiting_login!
      assert flow.begin_capture
      result = flow.finish_capture({ gsessionid: "smoke-session", account_index: "2", dossier_index: "5" }.freeze)

      assert_equal :captured, result.fetch(:state)
      assert_equal %i[expires_at id state], result.keys.sort
      assert_equal identity, callback_arguments.fetch(:identity)
      assert_equal "smoke-session", callback_arguments.fetch(:session).fetch(:gsessionid)
      refute flow.active?
      assert runtime_lock.closed?
    ensure
      runtime_lock&.close unless runtime_lock&.closed?
    end
  end

  test "diagnostic flow remains viewable and never begins a capture" do
    identity = { family_id: "family-1", user_id: "user-2", session_id: "session-3" }.freeze
    callback_called = false
    Dir.mktmpdir("fineco-runtime-lock-") do |directory|
      runtime_lock = File.open(File.join(directory, "runtime.lock"), File::RDWR | File::CREAT, 0o600)
      runtime_lock.flock(File::LOCK_EX | File::LOCK_NB)
      flow = Fineco::BrowserLoginRuntime::Flow.new(
        id: "b" * 32,
        identity: identity,
        on_capture: ->(**_arguments) { callback_called = true },
        authorized: ->(candidate) { candidate == identity },
        capture_enabled: false,
        runtime_lock: runtime_lock
      )
      flow.awaiting_login!

      assert_equal :setup_verification_required, flow.result.fetch(:state)
      refute flow.begin_capture
      assert flow.active?
      refute callback_called
      flow.terminate!(:stopped)
      refute flow.active?
      refute callback_called
    ensure
      runtime_lock&.close unless runtime_lock&.closed?
    end
  end

  test "websocket endpoint rejects a duplicate id before resolving the session" do
    calls = 0
    endpoint = websocket_endpoint(identity_resolver: ->(_env) { calls += 1; nil })
    env = rack_env("/", "id=#{'a' * 32}&id=#{'a' * 32}")

    status, = endpoint.call(env)

    assert_equal 400, status
    assert_equal 0, calls
  end

  test "websocket endpoint requires the exact origin" do
    endpoint = websocket_endpoint(identity_resolver: ->(_env) { flunk "identity resolver must not run" })
    env = rack_env("/", "id=#{'a' * 32}").merge("HTTP_ORIGIN" => "https://evil.example")

    status, = endpoint.call(env)

    assert_equal 403, status
  end

  test "websocket endpoint checks identity before requiring rack hijack" do
    endpoint = websocket_endpoint(identity_resolver: ->(_env) { { family_id: "1", user_id: "2", session_id: "3" } })
    env = rack_env("/", "id=#{'a' * 32}").merge(
      "HTTP_CONNECTION" => "Upgrade",
      "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_VERSION" => "13",
      "HTTP_SEC_WEBSOCKET_KEY" => "key"
    )

    status, = endpoint.call(env)

    assert_equal 501, status
  end

  test "asset endpoint serves only bounded noVNC core and vendor files" do
    Dir.mktmpdir("fineco-assets-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "core"))
      FileUtils.mkdir_p(File.join(directory, "vendor"))
      File.write(File.join(directory, "core", "rfb.js"), "export class RFB {}")
      File.write(File.join(directory, "vendor", "library.js"), "export const library = true;")
      File.write(File.join(directory, "LICENSE.txt"), "MPL-2.0")
      endpoint = Fineco::BrowserLoginRuntime::AssetEndpoint.new(root: directory)

      status, headers, body = endpoint.call(rack_env("/core/rfb.js", ""))
      assert_equal 200, status
      assert_equal "text/javascript; charset=utf-8", headers.fetch("Content-Type")
      assert_equal "no-store", headers.fetch("Cache-Control")
      assert_includes body.join, "class RFB"
      assert_equal 200, endpoint.call(rack_env("/vendor/library.js", ""))[0]
      assert_equal 200, endpoint.call(rack_env("/LICENSE.txt", ""))[0]
      assert_equal 404, endpoint.call(rack_env("/app/ui.js", ""))[0]
      assert_equal 404, endpoint.call(rack_env("/core/%2e%2e/app/ui.js", ""))[0]

      Dir.mktmpdir("fineco-asset-target-") do |outside|
        File.write(File.join(outside, "outside.js"), "do not serve")
        File.symlink(outside, File.join(directory, "core", "external"))
        assert_equal 404, endpoint.call(rack_env("/core/external/outside.js", ""))[0]
      end
    end
  end

  private

    def websocket_endpoint(identity_resolver:)
      Fineco::BrowserLoginRuntime::WebSocketEndpoint.new(
        runtime: Fineco::BrowserLoginRuntime,
        identity_resolver: identity_resolver,
        authorized: ->(_identity) { true },
        expected_origin: ->(_env) { "https://sure.example" }
      )
    end

    def rack_env(path, query)
      Rack::MockRequest.env_for("https://sure.example/fineco_login/stream").merge(
        "PATH_INFO" => path,
        "QUERY_STRING" => query,
        "REQUEST_METHOD" => "GET",
        "HTTP_ORIGIN" => "https://sure.example"
      )
    end

    def execute_account_context_expression(page_url:, payload:)
      javascript = <<~JAVASCRIPT
        const fs = require("fs");
        const vm = require("vm");
        (async () => {
          const input = JSON.parse(fs.readFileSync(0, "utf8"));
          const bytes = Buffer.from(JSON.stringify(input.payload), "utf8");
          const body = new ReadableStream({
            start(controller) {
              controller.enqueue(new Uint8Array(bytes));
              controller.close();
            }
          });
          let fetchCalls = 0;
          const context = {
            URL,
            location: new URL(input.page_url),
            AbortController,
            TextDecoder,
            Uint8Array,
            setTimeout,
            clearTimeout,
            fetch: async (url, options) => {
              fetchCalls += 1;
              if (url !== "https://private-api.finecobank.com/v1/private/users/accounts" ||
                  options.method !== "GET" || options.mode !== "cors" ||
                  options.credentials !== "include" || options.redirect !== "error" ||
                  options.cache !== "no-store") throw new Error("unexpected request");
              return {
                status: 200,
                redirected: false,
                url,
                headers: new Headers({ "content-length": String(bytes.byteLength) }),
                body
              };
            }
          };
          const value = await vm.runInNewContext(input.expression, context);
          process.stdout.write(JSON.stringify({ value, fetch_calls: fetchCalls }));
        })().catch(error => {
          process.stderr.write(error.stack || String(error));
          process.exit(1);
        });
      JAVASCRIPT
      stdout, stderr, status = Open3.capture3(
        "node",
        "-e",
        javascript,
        stdin_data: JSON.generate(
          expression: Observer::ACCOUNT_CONTEXT_EXPRESSION,
          page_url: page_url,
          payload: payload
        )
      )
      assert status.success?, stderr
      JSON.parse(stdout)
    end
end
