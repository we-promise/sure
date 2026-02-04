# frozen_string_literal: true

# Provides centralized SSL configuration for HTTP clients.
#
# This module enables support for self-signed certificates in self-hosted
# environments by reading configuration from Rails.configuration.x.ssl.
#
# Features:
#   - Custom CA certificate support for self-signed certificates
#   - Optional SSL verification bypass (for development/testing only)
#   - Debug logging for troubleshooting SSL issues
#   - Error wrapping with descriptive messages
#
# Usage with extend (for class methods):
#   class MyHttpClient
#     extend SslConfigurable
#
#     def self.make_request
#       Faraday.new(url, ssl: faraday_ssl_options) { |f| ... }
#     end
#   end
#
# Usage with include (for instance methods):
#   class MyProvider
#     include SslConfigurable
#
#     def make_request
#       Faraday.new(url, ssl: faraday_ssl_options) { |f| ... }
#     end
#   end
#
# Environment Variables (configured in config/initializers/ssl.rb):
#   SSL_CA_FILE - Path to custom CA certificate file (PEM format)
#   SSL_VERIFY  - Set to "false" to disable SSL verification
#   SSL_DEBUG   - Set to "true" to enable verbose SSL logging
module SslConfigurable
  # Custom error class for SSL-related errors
  class SslError < StandardError
    attr_reader :original_error, :url

    def initialize(message, original_error: nil, url: nil)
      @original_error = original_error
      @url = url
      super(build_message(message))
    end

    private

      def build_message(message)
        parts = [ message ]
        parts << "URL: #{redact_url(url)}" if url.present?
        parts << "Original error: #{original_error.message}" if original_error.present?
        parts.join(" | ")
      end

      # Redacts sensitive information from URLs (userinfo, credentials in query params)
      def redact_url(url_string)
        return url_string if url_string.blank?

        begin
          uri = URI.parse(url_string)
          # Redact userinfo (username:password@ in URL)
          uri.userinfo = "[REDACTED]" if uri.userinfo.present?
          # Return only scheme, host, port, and path (no query params)
          "#{uri.scheme}://#{uri.userinfo ? "#{uri.userinfo}@" : ""}#{uri.host}#{uri.port != uri.default_port ? ":#{uri.port}" : ""}#{uri.path}"
        rescue URI::InvalidURIError
          "[invalid URL]"
        end
      end
  end

  # Returns SSL options hash for Faraday connections
  #
  # @return [Hash] SSL options for Faraday
  # @example
  #   Faraday.new(url, ssl: faraday_ssl_options) do |f|
  #     f.request :json
  #     f.response :raise_error
  #   end
  def faraday_ssl_options
    options = {}
    ssl_config = ssl_configuration

    # Set verify based on explicit false check (nil or true both enable verification)
    options[:verify] = ssl_config.verify != false

    if ssl_config.ca_file.present?
      options[:ca_file] = ssl_config.ca_file
      log_ssl_debug("Faraday SSL: Using custom CA file: #{ssl_config.ca_file}")
    end

    if ssl_config.verify == false
      log_ssl_debug("Faraday SSL: Verification disabled")
    end

    log_ssl_debug("Faraday SSL options: #{options.inspect}") if options.present?
    options
  end

  # Returns SSL options hash for HTTParty requests
  #
  # @return [Hash] SSL options for HTTParty
  # @example
  #   class MyProvider
  #     include HTTParty
  #     extend SslConfigurable
  #     default_options.merge!(httparty_ssl_options)
  #   end
  def httparty_ssl_options
    ssl_config = ssl_configuration
    # Use explicit false check - nil or true both enable verification
    # HTTParty only uses :verify boolean, not :ssl_verify_mode
    verify_enabled = ssl_config.verify != false
    options = { verify: verify_enabled }

    if ssl_config.ca_file.present?
      options[:ssl_ca_file] = ssl_config.ca_file
      log_ssl_debug("HTTParty SSL: Using custom CA file: #{ssl_config.ca_file}")
    end

    if ssl_config.verify == false
      log_ssl_debug("HTTParty SSL: Verification disabled")
    end

    options
  end

  # Returns SSL verify mode for Net::HTTP
  #
  # @return [Integer] OpenSSL verify mode constant (VERIFY_PEER or VERIFY_NONE)
  # @example
  #   http = Net::HTTP.new(uri.host, uri.port)
  #   http.use_ssl = true
  #   http.verify_mode = net_http_verify_mode
  #   http.ca_file = ssl_ca_file if ssl_ca_file.present?
  def net_http_verify_mode
    ssl_config = ssl_configuration
    # Use explicit false check - nil or true both enable verification
    mode = ssl_config.verify != false ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    log_ssl_debug("Net::HTTP verify mode: #{mode == OpenSSL::SSL::VERIFY_PEER ? 'VERIFY_PEER' : 'VERIFY_NONE'}")
    mode
  end

  # Returns CA file path if configured and valid
  #
  # @return [String, nil] Path to CA file or nil if not configured
  def ssl_ca_file
    ssl_configuration.ca_file
  end

  # Returns whether SSL verification is enabled
  #
  # @return [Boolean] true if SSL verification is enabled
  def ssl_verify?
    ssl_configuration.verify != false
  end

  # Returns whether SSL debug logging is enabled
  #
  # @return [Boolean] true if debug logging is enabled
  def ssl_debug?
    ssl_configuration.debug
  end

  # Returns whether a custom CA file is configured and valid
  #
  # @return [Boolean] true if custom CA is configured and valid
  def ssl_custom_ca_configured?
    ssl_configuration.ca_file.present? && ssl_configuration.ca_file_valid
  end

  # Returns a summary of the current SSL configuration
  #
  # @return [Hash] Configuration summary
  def ssl_config_summary
    ssl_config = ssl_configuration
    {
      verify: ssl_config.verify,
      ca_file: ssl_config.ca_file,
      ca_file_valid: ssl_config.ca_file_valid,
      debug: ssl_config.debug
    }
  end

  # Wraps SSL-related errors with more descriptive messages
  #
  # @param url [String] The URL that was being accessed
  # @yield The block to execute
  # @raise [SslError] If an SSL error occurs
  # @example
  #   with_ssl_error_handling("https://example.com") do
  #     Faraday.get("https://example.com/api")
  #   end
  def with_ssl_error_handling(url = nil)
    yield
  rescue OpenSSL::SSL::SSLError => e
    handle_ssl_error(e, url)
  rescue Faraday::SSLError => e
    handle_ssl_error(e, url)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    # Re-raise timeout errors as-is, they're not SSL-specific
    raise
  rescue => e
    # Check if it's an SSL-related error wrapped in another exception
    if ssl_related_error?(e)
      handle_ssl_error(e, url)
    else
      raise
    end
  end

  private

    # Returns the SSL configuration from Rails
    #
    # @return [ActiveSupport::OrderedOptions] SSL configuration
    def ssl_configuration
      Rails.configuration.x.ssl
    end

    # Logs a debug message if SSL debug mode is enabled
    #
    # @param message [String] Message to log
    def log_ssl_debug(message)
      return unless ssl_configuration.debug

      caller_info = caller_locations(2, 1).first
      source = "#{caller_info.path.split('/').last}:#{caller_info.lineno}"
      Rails.logger.debug("[SSL Debug] [#{source}] #{message}")
    end

    # Handles SSL errors by wrapping them with descriptive messages
    #
    # @param error [Exception] The original error
    # @param url [String] The URL that was being accessed
    # @raise [SslError] Always raises with enhanced message
    def handle_ssl_error(error, url)
      message = build_ssl_error_message(error)
      redacted_url = redact_url_for_logging(url)

      Rails.logger.error("[SSL] Connection failed: #{message}")
      Rails.logger.error("[SSL] URL: #{redacted_url}") if redacted_url.present?
      Rails.logger.error("[SSL] Original error: #{error.class}: #{error.message}")

      if ssl_debug?
        Rails.logger.error("[SSL] Backtrace: #{error.backtrace&.first(5)&.join("\n")}")
      end

      # Log hints for resolution
      log_ssl_error_hints(error)

      raise SslError.new(message, original_error: error, url: url)
    end

    # Builds a user-friendly error message for SSL errors
    #
    # @param error [Exception] The original error
    # @return [String] User-friendly error message
    def build_ssl_error_message(error)
      error_message = error.message.to_s.downcase

      if error_message.include?("self-signed certificate") ||
         error_message.include?("self signed certificate")
        "SSL certificate verification failed: self-signed certificate detected. " \
          "Configure SSL_CA_FILE with your CA certificate or set SSL_VERIFY=false for testing."

      elsif error_message.include?("certificate verify failed")
        "SSL certificate verification failed. The server's certificate could not be verified. " \
          "If using a self-signed certificate, configure SSL_CA_FILE with your CA certificate."

      elsif error_message.include?("certificate has expired")
        "SSL certificate has expired. Please renew the server's certificate."

      elsif error_message.include?("hostname") || error_message.include?("host name")
        "SSL hostname verification failed. The certificate does not match the requested hostname."

      elsif error_message.include?("unknown ca") || error_message.include?("unknown certificate authority")
        "SSL certificate issued by unknown CA. Configure SSL_CA_FILE with the CA certificate."

      else
        "SSL connection error: #{error.message}"
      end
    end

    # Logs hints for resolving SSL errors
    #
    # @param error [Exception] The original error
    def log_ssl_error_hints(error)
      ssl_config = ssl_configuration
      error_message = error.message.to_s.downcase

      if error_message.include?("self-signed") || error_message.include?("certificate verify failed")
        Rails.logger.info("[SSL] Hint: To resolve this error, you can:")
        Rails.logger.info("[SSL]   1. Set SSL_CA_FILE=/path/to/your/ca-certificate.crt")
        Rails.logger.info("[SSL]   2. Or for testing only: Set SSL_VERIFY=false")

        if ssl_config.ca_file.present? && !ssl_config.ca_file_valid
          Rails.logger.warn("[SSL] Note: SSL_CA_FILE is configured but invalid: #{ssl_config.ca_file_error}")
        end
      end
    end

    # Redacts sensitive information from URLs for logging
    # Removes userinfo and query parameters to prevent credential leakage
    #
    # @param url_string [String] The URL to redact
    # @return [String, nil] Redacted URL or nil if blank
    def redact_url_for_logging(url_string)
      return nil if url_string.blank?

      begin
        uri = URI.parse(url_string)
        # Build redacted URL with only scheme, host, port, and path
        redacted = "#{uri.scheme}://#{uri.host}"
        redacted += ":#{uri.port}" if uri.port && uri.port != uri.default_port
        redacted += uri.path if uri.path.present?
        redacted
      rescue URI::InvalidURIError
        "[invalid URL]"
      end
    end

    # Checks if an error is SSL-related
    #
    # @param error [Exception] The error to check
    # @return [Boolean] true if the error is SSL-related
    def ssl_related_error?(error)
      message = error.message.to_s.downcase
      # Use specific keywords to avoid false positives (e.g., "verify" alone could match "verify your email")
      ssl_keywords = %w[ssl certificate tls handshake]
      ssl_phrases = [ "verify failed", "verification failed" ]
      ssl_keywords.any? { |keyword| message.include?(keyword) } ||
        ssl_phrases.any? { |phrase| message.include?(phrase) }
    end
end
