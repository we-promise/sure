# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "uri"

class Provider::Directa
  class HttpTransport
    Response = Data.define(:status, :body, :retry_after) do
      def initialize(status:, body:, retry_after: nil)
        super(status: status, body: body, retry_after: retry_after)
      end
    end

    ROUTES = {
      login: [ :post, LOGIN_PATH ],
      account_identity: [ :get, ACCOUNT_IDENTITY_PATH ],
      startup_metadata: [ :get, STARTUP_METADATA_PATH ],
      instrument_metadata: [ :get, INSTRUMENT_METADATA_PATH ],
      executed_orders: [ :get, "/trading/zordj" ],
      account_statement: [ :get, "/trading/estconc8" ]
    }.freeze
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10
    WRITE_TIMEOUT_SECONDS = 5
    MAX_QUERY_BYTES = 64 * 1024

    class RequestTimeout < StandardError; end

    def request(operation, query: nil, form: nil, deadline:, body_limit:)
      method, path = ROUTES.fetch(operation) do
        raise ConfigurationError.new("Directa request is not allowed.", failure_code: :request_not_allowed)
      end
      validate_body_limit!(body_limit)
      uri = request_uri(path, query)
      request = build_request(method, uri, form)
      body = +"".b
      status = nil
      retry_after = nil
      run_with_deadline(deadline) do
        http = build_http(deadline)
        http.start do |connection|
          connection.request(request) do |response|
            status = response.code.to_i
            retry_after = response["Retry-After"]
            content_length = response["content-length"].to_i if response["content-length"].to_s.match?(/\A\d+\z/)
            if content_length && content_length > body_limit
              raise ResponseTooLarge.new("Directa response exceeded the size limit.", failure_code: :response_too_large)
            end

            response.read_body do |chunk|
              if body.bytesize + chunk.bytesize > body_limit
                raise ResponseTooLarge.new("Directa response exceeded the size limit.", failure_code: :response_too_large)
              end
              body << chunk
              ensure_time_remaining!(deadline)
            end
          end
        end
      end
      Response.new(status: status, body: body.force_encoding(Encoding::UTF_8).freeze, retry_after: retry_after)
    rescue RequestTimeout
      raise
    rescue ResponseTooLarge
      raise
    rescue ConfigurationError
      raise
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise RequestTimeout, cause: nil
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPError
      raise ProviderUnavailable.new("Directa request failed.", failure_code: :provider_unavailable), cause: nil
    end

    private

      def request_uri(path, query)
        uri = URI::HTTPS.build(host: HOST, port: HTTPS_PORT, path: path)
        if query
          unless query.is_a?(Hash) && query.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
            raise ConfigurationError.new("Directa request parameters are invalid.", failure_code: :request_invalid)
          end

          encoded_query = URI.encode_www_form(query.to_a)
          if encoded_query.bytesize > MAX_QUERY_BYTES
            raise ConfigurationError.new("Directa request parameters are too large.", failure_code: :request_too_large)
          end
          uri.query = encoded_query
        end
        uri
      end

      def build_request(method, uri, form)
        request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        request = request_class.new(uri.request_uri)
        request["Accept"] = "application/json, text/plain, */*"
        request["User-Agent"] = USER_AGENT
        return request unless method == :post

        unless form.is_a?(Array) && form.all? { |pair| pair.is_a?(Array) && pair.length == 2 && pair.all? { |value| value.is_a?(String) } }
          raise ConfigurationError.new("Directa login request is invalid.", failure_code: :request_invalid)
        end
        request.set_form_data(form)
        request
      end

      def build_http(deadline)
        remaining = ensure_time_remaining!(deadline)
        http = Net::HTTP.new(HOST, HTTPS_PORT, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true if http.respond_to?(:verify_hostname=)
        http.open_timeout = [ OPEN_TIMEOUT_SECONDS, remaining ].min
        http.read_timeout = [ READ_TIMEOUT_SECONDS, remaining ].min
        http.write_timeout = [ WRITE_TIMEOUT_SECONDS, remaining ].min
        http.max_retries = 0 if http.respond_to?(:max_retries=)
        http
      end

      def validate_body_limit!(body_limit)
        unless body_limit.is_a?(Integer) && body_limit.positive? && body_limit <= HTTP_BODY_LIMIT_BYTES
          raise ConfigurationError.new("Directa response limit is invalid.", failure_code: :request_invalid)
        end
      end

      def run_with_deadline(deadline)
        remaining = ensure_time_remaining!(deadline)
        Timeout.timeout(remaining, RequestTimeout) { yield }
      rescue RequestTimeout
        raise
      rescue Timeout::Error
        raise RequestTimeout, cause: nil
      end

      def ensure_time_remaining!(deadline)
        remaining = deadline.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise RequestTimeout, cause: nil unless remaining.positive?

        remaining
      end
  end
end
