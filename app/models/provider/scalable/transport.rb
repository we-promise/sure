require "json"
require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"

class Provider::Scalable
  module Transport
    Response = Data.define(:status, :headers, :body)

    MAX_RESPONSE_BYTES = 5 * 1024 * 1024
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 15
    WRITE_TIMEOUT_SECONDS = 5
    USER_AGENT = "Sure Scalable Capital Connector".freeze

    private

      def http_request(url, method:, body: nil, headers: {}, allowed_hosts:)
        uri = validate_https_uri!(url, allowed_hosts: allowed_hosts)
        request_class = {
          get: Net::HTTP::Get,
          post: Net::HTTP::Post
        }.fetch(method) { raise Error.new(:invalid_request) }
        request = request_class.new(uri.request_uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = USER_AGENT
        headers.each { |name, value| request[name] = value.to_s }
        request.body = body if body

        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = OPEN_TIMEOUT_SECONDS
        http.read_timeout = READ_TIMEOUT_SECONDS
        http.write_timeout = WRITE_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
        http.max_retries = 0 if http.respond_to?(:max_retries=)

        wrapped_response = nil
        http.request(request) do |raw_response|
          response_body = +""
          raw_response.read_body do |chunk|
            if response_body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
              raise Error.new(:response_too_large)
            end
            response_body << chunk
          end

          wrapped_response = Response.new(
            status: raw_response.code.to_i,
            headers: raw_response.each_header.to_h,
            body: response_body
          )
        end
        wrapped_response || raise(Error.new(:invalid_response))
      rescue Error
        raise
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
        raise Error.new(:request_timeout), cause: nil
      rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, EOFError, IOError, Net::HTTPError
        raise Error.new(:provider_unavailable), cause: nil
      end

      def validate_https_uri!(raw_url, allowed_hosts:)
        uri = URI.parse(raw_url.to_s)
        host = uri.host.to_s.downcase
        allowed = Array(allowed_hosts).map { |value| value.to_s.downcase }

        unless uri.is_a?(URI::HTTPS) && allowed.include?(host) && uri.port == 443 &&
            uri.userinfo.nil? && uri.fragment.nil?
          raise Error.new(:unsafe_endpoint)
        end

        uri
      rescue URI::InvalidURIError
        raise Error.new(:unsafe_endpoint), cause: nil
      end

      def json_response!(response)
        unless (200..299).cover?(response.status)
          raise Error.new(:provider_unavailable)
        end

        parsed = JSON.parse(response.body)
        raise Error.new(:invalid_response) unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Error.new(:invalid_response), cause: nil
      end

      def post_form(url, values, key_pem:, access_token: nil, allowed_hosts:)
        post_with_dpop(
          url,
          URI.encode_www_form(values),
          key_pem: key_pem,
          access_token: access_token,
          content_type: "application/x-www-form-urlencoded",
          allowed_hosts: allowed_hosts
        )
      end

      def post_json_with_dpop(url, payload, key_pem:, access_token:, allowed_hosts:)
        post_with_dpop(
          url,
          JSON.generate(payload),
          key_pem: key_pem,
          access_token: access_token,
          content_type: "application/json",
          allowed_hosts: allowed_hosts
        )
      end

      def post_with_dpop(url, body, key_pem:, access_token:, content_type:, allowed_hosts:)
        nonce = nil
        retried_nonce = false

        loop do
          headers = {
            "Content-Type" => content_type,
            "DPoP" => dpop_proof(
              key_pem,
              url,
              method: "POST",
              nonce: nonce,
              access_token: access_token
            )
          }
          headers["Authorization"] = "DPoP #{access_token}" if access_token.present?
          response = http_request(url, method: :post, body: body, headers: headers, allowed_hosts: allowed_hosts)

          retry_nonce = response.headers["dpop-nonce"].to_s.strip
          if !retried_nonce && !retry_nonce.empty? && dpop_nonce_challenge?(response)
            nonce = retry_nonce
            retried_nonce = true
            next
          end

          reject_redirect!(response)
          return response
        end
      end

      def dpop_nonce_challenge?(response)
        response.status == 401 || response.body.to_s.downcase.match?(/use_dpop_nonce|invalid_dpop_proof/)
      end

      def reject_redirect!(response)
        raise Error.new(:redirect_rejected) if (300..399).cover?(response.status)
      end
  end
end
