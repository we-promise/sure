# frozen_string_literal: true

require "base64"
require "json"
require "time"
require "uri"

require_relative "cdp_connection"

module Fineco
  class BrowserLoginRuntime
    class CaptureObserver
      PORTFOLIO_HOST = "private-api.finecobank.com".freeze
      PORTFOLIO_PATH = "/v1/private/tol/positions/summary".freeze
      PORTFOLIO_URL = "https://#{PORTFOLIO_HOST}#{PORTFOLIO_PATH}?type=sintesi".freeze
      MAX_RESPONSE_BODY_BYTES = 2 * 1024 * 1024
      MAX_TRACKED_REQUESTS = 32
      MAX_PAGE_SESSIONS = 16
      INDEX_PATTERN = /\A\d{1,6}\z/
      COOKIE_PATTERN = /\A[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]{1,512}\z/

      def initialize(flow)
        @flow = flow
        @pending_requests = {}
        @page_sessions = {}
        @last_authorization_check = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def run
        return unless @flow.capture_enabled?

        @connection = CdpConnection.new(browser_target_url).connect
        @connection.command("Target.setDiscoverTargets", { "discover" => true })
        @connection.command(
          "Target.setAutoAttach",
          {
            "autoAttach" => true,
            "waitForDebuggerOnStart" => false,
            "flatten" => true,
            "filter" => [ { "type" => "page", "exclude" => false } ]
          }
        )
        wait_for_page_session
        @flow.awaiting_login!
        observe
      rescue StandardError
        @flow.terminate!(:failed) if @flow.active?
      ensure
        @connection&.close
      end

      def self.portfolio_request?(url, method)
        return false unless method == "GET"

        parsed = URI.parse(url)
        parsed.scheme == "https" && parsed.host == PORTFOLIO_HOST && parsed.port == 443 &&
          parsed.userinfo.nil? && parsed.fragment.nil? && parsed.path == PORTFOLIO_PATH &&
          parsed.query == "type=sintesi"
      rescue URI::InvalidURIError, NoMethodError
        false
      end

      def self.request_indices(headers)
        account = header_value(headers, "x-account-index")
        dossier = header_value(headers, "x-dossier-index")
        return unless account&.match?(INDEX_PATTERN) && dossier&.match?(INDEX_PATTERN)

        { account_index: account, dossier_index: dossier }
      end

      def self.portfolio_schema?(payload)
        return false unless payload.is_a?(Hash)

        info = payload["info"]
        dossier = info.is_a?(Hash) ? info["dossier"] : nil
        positions = payload["positions"]
        rows = positions.is_a?(Hash) ? positions["show"] : nil
        summary = payload["summary"]

        dossier.is_a?(Hash) && dossier["blocked"] == false &&
          rows.is_a?(Array) && rows.length <= 2_000 && rows.all? { |row| row.is_a?(Hash) } &&
          summary.is_a?(Hash) && summary["show"].is_a?(Hash) && summary["total"].is_a?(Hash)
      end

      def self.gsessionid(cookies)
        candidates = cookies.select do |cookie|
          cookie.is_a?(Hash) && cookie["name"] == "gsessionid" &&
            cookie["secure"] == true && valid_cookie_domain?(cookie["domain"]) &&
            valid_cookie_path?(cookie["path"]) && cookie["value"].is_a?(String) &&
            cookie["value"].match?(COOKIE_PATTERN)
        end
        return if candidates.empty?

        candidates.sort_by! { |cookie| -cookie.fetch("path").length }
        return if candidates.length > 1 && candidates[0].fetch("path").length == candidates[1].fetch("path").length

        candidates.first.fetch("value")
      end

      private

        def observe
          while @flow.active?
            return @flow.terminate!(:expired) if @flow.expired?
            return @flow.terminate!(:rejected) unless authorized?
            return @flow.terminate!(:failed) unless @flow.processes_alive? && !@connection.closed?

            event = @connection.next_event(timeout: 1)
            process_event(event) if event
          end
        end

        def authorized?
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return true if now - @last_authorization_check < AUTHORIZATION_CHECK_INTERVAL

          @last_authorization_check = now
          @flow.authorized?
        end

        def browser_target_url
          response = local_http_get("/json/version", 3)
          raise CdpConnection::Error unless response.is_a?(Net::HTTPSuccess) && response.body.bytesize <= 256 * 1024

          target = JSON.parse(response.body)
          url = target["webSocketDebuggerUrl"]
          raise CdpConnection::Error unless url.is_a?(String)

          url
          end

        def process_event(event)
          method = event["method"]
          params = event["params"]
          return unless params.is_a?(Hash)

          case method
          when "Target.attachedToTarget"
            attach_page_session(params)
          when "Target.detachedFromTarget"
            detach_page_session(params["sessionId"])
          when "Network.requestWillBeSent"
            record_request(event["sessionId"], params)
          when "Network.responseReceived"
            mark_response_received(event["sessionId"], params)
          when "Network.loadingFinished"
            capture_completed_request(event["sessionId"], params)
          when "Network.loadingFailed"
            @pending_requests.delete([ event["sessionId"], params["requestId"] ])
          end
        end

        def wait_for_page_session
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
          while @page_sessions.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            event = @connection.next_event(timeout: 1)
            process_event(event) if event
          end
          raise CdpConnection::Error if @page_sessions.empty?
        end

        def attach_page_session(params)
          return unless @flow.capture_enabled?

          session_id = params["sessionId"]
          target = params["targetInfo"]
          return unless session_id.is_a?(String) && session_id.bytesize <= 128 && target.is_a?(Hash)
          return unless target["type"] == "page"
          return if @page_sessions.key?(session_id)
          return detach_target(session_id) if @page_sessions.length >= MAX_PAGE_SESSIONS

          @connection.command(
            "Network.enable",
            {
              "maxTotalBufferSize" => MAX_RESPONSE_BODY_BYTES,
              "maxResourceBufferSize" => MAX_RESPONSE_BODY_BYTES,
              "maxPostDataSize" => 0
            },
            session_id: session_id
          )
          @page_sessions[session_id] = target["targetId"]
        rescue StandardError
          detach_target(session_id)
        end

        def detach_page_session(session_id)
          @page_sessions.delete(session_id)
          @pending_requests.delete_if { |(session, _request_id), _indices| session == session_id }
        end

        def detach_target(session_id)
          @connection.command("Target.detachFromTarget", { "sessionId" => session_id }, timeout: 2)
        rescue StandardError
          nil
        end

        def record_request(session_id, params)
          return unless @flow.capture_enabled?
          return unless @page_sessions.key?(session_id)

          request = params["request"]
          return if params["redirectResponse"]
          return unless request.is_a?(Hash) && self.class.portfolio_request?(request["url"], request["method"])

          indices = self.class.request_indices(request["headers"])
          return unless indices

          request_id = params["requestId"].to_s
          return if request_id.empty? || request_id.bytesize > 128

          @pending_requests.shift while @pending_requests.length >= MAX_TRACKED_REQUESTS
          @pending_requests[[ session_id, request_id ]] = { indices: indices, response_received: false }
        end

        def mark_response_received(session_id, params)
          return unless @flow.capture_enabled?
          return unless @page_sessions.key?(session_id)

          request_id = params["requestId"].to_s
          pending = @pending_requests[[ session_id, request_id ]]
          return unless pending && %w[XHR Fetch].include?(params["type"])

          response = params["response"]
          unless response.is_a?(Hash) && response["status"] == 200 && response_body_size_allowed?(response["headers"])
            @pending_requests.delete([ session_id, request_id ])
            return
          end

          pending[:response_received] = true
        end

        def capture_completed_request(session_id, params)
          return unless @flow.capture_enabled?
          return unless @page_sessions.key?(session_id)

          request_id = params["requestId"].to_s
          pending = @pending_requests.delete([ session_id, request_id ])
          return unless pending && pending[:response_received]
          indices = pending.fetch(:indices)
          return unless @flow.begin_capture

          body_response = @connection.command("Network.getResponseBody", { "requestId" => request_id }, timeout: 8, session_id: session_id)
          body = decode_body(body_response)
          payload = JSON.parse(body)
          return @flow.capture_retryable unless self.class.portfolio_schema?(payload)

          cookie_response = @connection.command("Network.getCookies", { "urls" => [ PORTFOLIO_URL ] }, timeout: 5, session_id: session_id)
          cookies = cookie_response["cookies"]
          credential = cookies.is_a?(Array) ? self.class.gsessionid(cookies) : nil
          return @flow.capture_retryable unless credential

          @flow.finish_capture(
            {
              gsessionid: credential,
              account_index: indices.fetch(:account_index),
              dossier_index: indices.fetch(:dossier_index),
              captured_at: Time.now.utc.iso8601(6)
            }.freeze
          )
        rescue StandardError
          @flow.capture_retryable if @flow.current_state == :capturing
        end

        def response_body_size_allowed?(headers)
          return true unless headers.is_a?(Hash)

          value = headers.find { |name, _| name.to_s.casecmp("content-length").zero? }&.last
          return true if value.nil?
          return false unless value.to_s.match?(/\A\d{1,10}\z/)

          value.to_i <= MAX_RESPONSE_BODY_BYTES
        end

        def decode_body(response)
          value = response["body"]
          raise CdpConnection::Error unless value.is_a?(String) && value.bytesize <= 3 * MAX_RESPONSE_BODY_BYTES

          body = response["base64Encoded"] ? Base64.strict_decode64(value) : value
          raise CdpConnection::Error if body.bytesize > MAX_RESPONSE_BODY_BYTES

          body
        end

        def local_http_get(path, timeout)
          http = Net::HTTP.new("127.0.0.1", CHROME_DEBUGGING_PORT, nil)
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.request(Net::HTTP::Get.new(path))
        end

        def self.header_value(headers, expected_name)
          return unless headers.is_a?(Hash)

          matches = headers.filter_map do |name, value|
            value if name.to_s.casecmp(expected_name).zero?
          end
          return unless matches.one? && matches.first.is_a?(String) && matches.first.bytesize <= 6

          matches.first
        end

        def self.valid_cookie_domain?(domain)
          value = domain.to_s.downcase.sub(/\A\./, "")
          PORTFOLIO_HOST == value || PORTFOLIO_HOST.end_with?(".#{value}")
        end

        def self.valid_cookie_path?(path)
          value = path.to_s
          return false unless value.start_with?("/") && !value.include?("\\")

          PORTFOLIO_PATH == value || PORTFOLIO_PATH.start_with?(value.end_with?("/") ? value : "#{value}/")
        end
    end
  end
end
