# frozen_string_literal: true

require "openssl"
require "fileutils"

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
#
# IMPORTANT: When a valid SSL_CA_FILE is provided, this initializer sets the
# SSL_CERT_FILE environment variable to a combined CA bundle (system CAs + custom CA).
# This is a *global* side-effect that affects ALL SSL connections in the Ruby process,
# including gems that do not go through SslConfigurable (e.g. openid_connect).
# This is intentional — it ensures OIDC discovery, webhook callbacks, and any other
# outbound HTTPS connection trusts both public CAs and the user's custom CA.

# Path for the combined CA bundle file (predictable location for debugging)
COMBINED_CA_BUNDLE_PATH = Rails.root.join("tmp", "ssl_ca_bundle.pem").freeze

# Boot-time helper for SSL certificate validation and bundle creation.
#
# This is intentionally a standalone module (not nested under SslConfigurable)
# because SslConfigurable is autoloaded by Zeitwerk from app/models/concerns/.
# Reopening that module here at boot time would register the constant before
# Zeitwerk, preventing the real concern (with httparty_ssl_options, etc.) from
# ever being loaded — causing NameError at class load time in providers.
module SslInitializerHelper
  module_function

  # PEM certificate format markers (X.509 standard)
  PEM_CERT_BEGIN = "-----BEGIN CERTIFICATE-----"
  PEM_CERT_END = "-----END CERTIFICATE-----"

  # Validates a CA certificate file.
  # Supports single certs and multi-cert PEM bundles (CA chains).
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

    unless File.file?(path)
      result[:error] = "Path is not a file: #{path}"
      Rails.logger.warn("[SSL] SSL_CA_FILE specified but is not a file: #{path}")
      return result
    end

    # Sanity check file size (CA certs should be < 1MB)
    file_size = File.size(path)
    if file_size > 1_000_000
      result[:error] = "File too large (#{file_size} bytes) - expected a PEM certificate"
      Rails.logger.warn("[SSL] SSL_CA_FILE is unexpectedly large: #{path} (#{file_size} bytes)")
      return result
    end

    # Validate PEM format using standard X.509 markers
    content = File.read(path)
    unless content.include?(PEM_CERT_BEGIN)
      result[:error] = "Invalid PEM format - missing BEGIN CERTIFICATE marker"
      Rails.logger.warn("[SSL] SSL_CA_FILE does not appear to be a valid PEM certificate: #{path}")
      return result
    end

    unless content.include?(PEM_CERT_END)
      result[:error] = "Invalid PEM format - missing END CERTIFICATE marker"
      Rails.logger.warn("[SSL] SSL_CA_FILE has incomplete PEM format: #{path}")
      return result
    end

    # Parse and validate every certificate in the PEM file.
    # OpenSSL::X509::Certificate.new only parses the first PEM block,
    # so multi-cert bundles (CA chains) need per-block validation.
    begin
      pem_blocks = content.scan(/#{PEM_CERT_BEGIN}[\s\S]+?#{PEM_CERT_END}/)
      raise OpenSSL::X509::CertificateError, "No certificates found in PEM file" if pem_blocks.empty?

      pem_blocks.each_with_index do |pem, index|
        OpenSSL::X509::Certificate.new(pem)
      rescue OpenSSL::X509::CertificateError => e
        raise OpenSSL::X509::CertificateError, "Certificate #{index + 1} of #{pem_blocks.size} is invalid: #{e.message}"
      end

      result[:path] = path
      result[:valid] = true
    rescue OpenSSL::X509::CertificateError => e
      result[:error] = "Invalid certificate: #{e.message}"
      Rails.logger.warn("[SSL] SSL_CA_FILE contains invalid certificate: #{e.message}")
    end

    result
  end

  # Finds the system CA certificate bundle path using OpenSSL's detection
  #
  # @return [String, nil] Path to system CA bundle or nil if not found
  def find_system_ca_bundle
    # First, check if SSL_CERT_FILE is already set (user may have their own bundle)
    existing_cert_file = ENV["SSL_CERT_FILE"]
    if existing_cert_file.present? && File.exist?(existing_cert_file) && File.readable?(existing_cert_file)
      return existing_cert_file
    end

    # Use OpenSSL's built-in CA file detection
    openssl_ca_file = OpenSSL::X509::DEFAULT_CERT_FILE
    if openssl_ca_file.present? && File.exist?(openssl_ca_file) && File.readable?(openssl_ca_file)
      return openssl_ca_file
    end

    # Use OpenSSL's default certificate directory as fallback
    openssl_ca_dir = OpenSSL::X509::DEFAULT_CERT_DIR
    if openssl_ca_dir.present? && Dir.exist?(openssl_ca_dir)
      # Look for common bundle file names in the certificate directory
      %w[ca-certificates.crt ca-bundle.crt cert.pem].each do |bundle_name|
        bundle_path = File.join(openssl_ca_dir, bundle_name)
        return bundle_path if File.exist?(bundle_path) && File.readable?(bundle_path)
      end
    end

    nil
  end

  # Creates a combined CA bundle with system CAs and custom CA.
  # Writes to a predictable path (tmp/ssl_ca_bundle.pem) for easy debugging
  # and to avoid Tempfile GC lifecycle issues.
  #
  # @param custom_ca_path [String] Path to the custom CA certificate
  # @param output_path [String] Where to write the combined bundle
  # @return [String, nil] Path to the combined bundle, or nil on failure
  def create_combined_ca_bundle(custom_ca_path, output_path: COMBINED_CA_BUNDLE_PATH)
    system_ca = find_system_ca_bundle
    unless system_ca
      Rails.logger.warn("[SSL] Could not find system CA bundle - using custom CA only")
      return nil
    end

    begin
      system_content = File.read(system_ca)
      custom_content = File.read(custom_ca_path)

      # Ensure the parent directory exists
      FileUtils.mkdir_p(File.dirname(output_path))

      File.write(output_path, system_content + "\n# Custom CA Certificate\n" + custom_content)

      Rails.logger.info("[SSL] Created combined CA bundle: #{output_path}")
      Rails.logger.info("[SSL]   - System CA source: #{system_ca}")
      Rails.logger.info("[SSL]   - Custom CA source: #{custom_ca_path}")

      output_path.to_s
    rescue StandardError => e
      Rails.logger.error("[SSL] Failed to create combined CA bundle: #{e.message}")
      nil
    end
  end

  # Logs SSL configuration summary at startup
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
      Rails.logger.info("[SSL]   - Combined CA bundle: #{ssl_config.combined_ca_bundle || 'not created'}")
      Rails.logger.info("[SSL]   - SSL_CERT_FILE: #{ENV['SSL_CERT_FILE'] || 'not set'}")
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

  if ca_file
    ca_file_status = SslInitializerHelper.validate_ca_certificate_file(ca_file)
    config.x.ssl.ca_file = ca_file_status[:path]
    config.x.ssl.ca_file_valid = ca_file_status[:valid]
    config.x.ssl.ca_file_error = ca_file_status[:error]

    # Create combined CA bundle and set SSL_CERT_FILE for global SSL configuration.
    #
    # This sets ENV["SSL_CERT_FILE"] globally so that ALL Ruby SSL connections
    # (including gems like openid_connect that bypass SslConfigurable) will trust
    # both system CAs (for public services) and the custom CA (for self-signed services).
    if ca_file_status[:valid]
      combined_path = SslInitializerHelper.create_combined_ca_bundle(ca_file_status[:path])
      if combined_path
        config.x.ssl.combined_ca_bundle = combined_path
        ENV["SSL_CERT_FILE"] = combined_path
        Rails.logger.info("[SSL] Set SSL_CERT_FILE=#{combined_path} for global SSL configuration")
      else
        # Fallback: just use the custom CA (may break connections to public services)
        Rails.logger.warn("[SSL] Could not create combined CA bundle, using custom CA only. " \
          "Connections to public services (not using your custom CA) may fail.")
        ENV["SSL_CERT_FILE"] = ca_file_status[:path]
      end
    end
  end

  # Log configuration summary at startup
  SslInitializerHelper.log_ssl_configuration(config.x.ssl)
end
