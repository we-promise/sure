# frozen_string_literal: true

# Centralized SSL/TLS configuration for outbound HTTPS connections.
#
# This enables support for self-signed certificates in self-hosted environments
# where servers use internal CAs or self-signed certificates.
#
# Environment Variables:
#   SSL_CA_FILE - Path to custom CA certificate file (PEM format)
#   SSL_VERIFY  - Set to "false" to disable SSL verification (NOT RECOMMENDED for production)
#   SSL_DEBUG   - Set to "true" to enable verbose SSL logging
#
# Example usage in docker-compose.yml:
#   environment:
#     SSL_CA_FILE: /certs/my-ca.crt
#   volumes:
#     - ./my-ca.crt:/certs/my-ca.crt:ro
#
# Security Warning:
#   Disabling SSL verification (SSL_VERIFY=false) removes protection against
#   man-in-the-middle attacks. Only use this for development/testing environments.

# Helper module for SSL configuration validation and logging
# Defined before Rails.application.configure to ensure methods are available
module SslInitializerHelper
  module_function

  # Validates a CA certificate file
  #
  # @param path [String] Path to the CA certificate file
  # @return [Hash] Validation result with :path, :valid, and :error keys
  def validate_ca_certificate_file(path)
    result = { path: nil, valid: false, error: nil }

    unless File.exist?(path)
      result[:error] = "File not found: #{path}"
      Rails.logger.warn("[SSL] SSL_CA_FILE specified but file not found: #{path}")
      return result
    end

    unless File.readable?(path)
      result[:error] = "File not readable: #{path}"
      Rails.logger.warn("[SSL] SSL_CA_FILE specified but file not readable: #{path}")
      return result
    end

    # Validate PEM format
    content = File.read(path)
    unless content.include?("-----BEGIN CERTIFICATE-----")
      result[:error] = "Invalid PEM format - missing BEGIN CERTIFICATE marker"
      Rails.logger.warn("[SSL] SSL_CA_FILE does not appear to be a valid PEM certificate: #{path}")
      return result
    end

    unless content.include?("-----END CERTIFICATE-----")
      result[:error] = "Invalid PEM format - missing END CERTIFICATE marker"
      Rails.logger.warn("[SSL] SSL_CA_FILE has incomplete PEM format: #{path}")
      return result
    end

    # Try to parse the certificate
    begin
      OpenSSL::X509::Certificate.new(content)
      result[:path] = path
      result[:valid] = true
    rescue OpenSSL::X509::CertificateError => e
      result[:error] = "Invalid certificate: #{e.message}"
      Rails.logger.warn("[SSL] SSL_CA_FILE contains invalid certificate: #{e.message}")
    end

    result
  end

  # Logs SSL configuration summary
  #
  # @param ssl_config [ActiveSupport::OrderedOptions] SSL configuration
  def log_ssl_configuration(ssl_config)
    if ssl_config.debug
      Rails.logger.info("[SSL] Debug mode enabled - verbose SSL logging active")
    end

    if ssl_config.ca_file.present?
      if ssl_config.ca_file_valid
        Rails.logger.info("[SSL] Custom CA certificate configured and validated: #{ssl_config.ca_file}")
      else
        Rails.logger.error("[SSL] Custom CA certificate configured but invalid: #{ssl_config.ca_file_error}")
      end
    end

    unless ssl_config.verify
      Rails.logger.warn("[SSL] " + "=" * 60)
      Rails.logger.warn("[SSL] WARNING: SSL verification is DISABLED")
      Rails.logger.warn("[SSL] This is insecure and should only be used for development/testing")
      Rails.logger.warn("[SSL] Set SSL_VERIFY=true or remove the variable for production")
      Rails.logger.warn("[SSL] " + "=" * 60)
    end

    if ssl_config.debug
      Rails.logger.info("[SSL] Configuration summary:")
      Rails.logger.info("[SSL]   - SSL verification: #{ssl_config.verify ? 'ENABLED' : 'DISABLED'}")
      Rails.logger.info("[SSL]   - Custom CA file: #{ssl_config.ca_file || 'not configured'}")
      Rails.logger.info("[SSL]   - CA file valid: #{ssl_config.ca_file_valid}")
    end
  end
end

# Configure SSL settings
Rails.application.configure do
  config.x.ssl ||= ActiveSupport::OrderedOptions.new

  truthy_values = %w[1 true yes on].freeze
  falsy_values = %w[0 false no off].freeze

  # Debug mode for verbose SSL logging
  debug_env = ENV["SSL_DEBUG"].to_s.strip.downcase
  config.x.ssl.debug = truthy_values.include?(debug_env)

  # SSL verification (default: true)
  verify_env = ENV["SSL_VERIFY"].to_s.strip.downcase
  config.x.ssl.verify = !falsy_values.include?(verify_env)

  # Custom CA certificate file for trusting self-signed certificates
  ca_file = ENV["SSL_CA_FILE"].presence
  config.x.ssl.ca_file = nil
  config.x.ssl.ca_file_valid = false

  if ca_file.present?
    ca_file_status = SslInitializerHelper.validate_ca_certificate_file(ca_file)
    config.x.ssl.ca_file = ca_file_status[:path]
    config.x.ssl.ca_file_valid = ca_file_status[:valid]
    config.x.ssl.ca_file_error = ca_file_status[:error]
  end

  # Log configuration summary at startup
  SslInitializerHelper.log_ssl_configuration(config.x.ssl)
end
