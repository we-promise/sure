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
#
# Usage (extend for class methods — the only supported pattern):
#   class MyHttpClient
#     extend SslConfigurable
#
#     def self.make_request
#       Faraday.new(url, ssl: faraday_ssl_options) { |f| ... }
#     end
#   end
#
# Environment Variables (configured in config/initializers/00_ssl.rb):
#   SSL_CA_FILE - Path to custom CA certificate file (PEM format)
#   SSL_VERIFY  - Set to "false" to disable SSL verification
#   SSL_DEBUG   - Set to "true" to enable verbose SSL logging
module SslConfigurable
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

    options[:verify] = ssl_verify?

    if ssl_ca_file.present?
      options[:ca_file] = ssl_ca_file
      log_ssl_debug("Faraday SSL: Using custom CA file: #{ssl_ca_file}")
    end

    log_ssl_debug("Faraday SSL: Verification disabled") unless ssl_verify?
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
    options = { verify: ssl_verify? }

    if ssl_ca_file.present?
      options[:ssl_ca_file] = ssl_ca_file
      log_ssl_debug("HTTParty SSL: Using custom CA file: #{ssl_ca_file}")
    end

    log_ssl_debug("HTTParty SSL: Verification disabled") unless ssl_verify?

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
    mode = ssl_verify? ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    log_ssl_debug("Net::HTTP verify mode: #{mode == OpenSSL::SSL::VERIFY_PEER ? 'VERIFY_PEER' : 'VERIFY_NONE'}")
    mode
  end

  # Returns CA file path if configured
  #
  # @return [String, nil] Path to CA file or nil if not configured
  def ssl_ca_file
    ssl_configuration.ca_file
  end

  # Returns whether SSL verification is enabled
  # nil or true both mean verification is enabled; only explicit false disables it
  #
  # @return [Boolean] true if SSL verification is enabled
  def ssl_verify?
    ssl_configuration.verify != false
  end

  # Returns whether SSL debug logging is enabled
  #
  # @return [Boolean] true if debug logging is enabled
  def ssl_debug?
    ssl_configuration.debug == true
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
      return unless ssl_debug?

      Rails.logger.debug("[SSL Debug] #{message}")
    end
end
