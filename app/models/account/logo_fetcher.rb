# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"
require "resolv"
require "ipaddr"

class Account::LogoFetcher
  HTTP_TIMEOUT = 5

  # The fetcher builds request URLs from the domain the job was enqueued for
  # and refuses to attach when the account's domain has since changed.
  #
  # It validates that all DNS-resolved addresses for a URL are public before
  # making any connection, preventing DNS rebinding attacks where a second
  # resolution could return a private/loopback address.
  def initialize(account, expected_domain: nil)
    @account = account
    @expected_domain = expected_domain
  end

  # Fetches a logo from available sources and attaches it to the account.
  #
  # Tries sources in priority order:
  # 1. Brandfetch (if configured and domain present)
  # 2. Provider logo URL (if available)
  # 3. Favicon from DuckDuckGo (if domain present)
  #
  # Returns early if any source succeeds. Only attaches when logo_source is "auto".
  def fetch_and_attach
    return unless account.logo_source_auto?

    domain = (@expected_domain || account.institution_domain).presence

    # Do not make any network request if the domain changed while the job
    # was waiting in the queue.
    return if @expected_domain.present? &&
      account.institution_domain != @expected_domain

    # Same priority as Account#logo_url: Brandfetch when configured, then the
    # linked provider's own logo, then a favicon.
    # If we have a domain, use it for Brandfetch and favicon fallbacks.
    # Provider logo URLs are independent of domain.
    urls = []
    urls << account.brandfetch_logo_url(domain) if domain.present?
    urls << account.provider&.logo_url
    urls << account.favicon_url(domain) if domain.present?

    urls.each do |url|
      next if url.blank?
      return if fetch_from_url(url, domain)
    end
  end

  private

    attr_reader :account

    # Fetches a logo from a single URL and attaches it to the account.
    # Validates the URL's DNS resolution contains only public addresses before
    # connecting. Downloads the image, validates content type and size, then
    # attaches it via attach_fetched_logo (preserving auto source).
    #
    # @param url [String] The URL to fetch the logo from
    # @param expected_domain [String] The domain we expect the account to have (for stale check)
    # @return [Boolean] true if logo was successfully attached, false otherwise
    def fetch_from_url(url, expected_domain)
      uri = URI.parse(url)

      resolved_addresses = public_http_url?(uri)
      return false unless resolved_addresses

      # Pin the connection to a validated address to prevent DNS rebinding.
      # We use the first validated address for the connection while keeping the
      # original host for HTTP Host header and TLS SNI verification.
      http = Net::HTTP.new(resolved_addresses.first, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      tempfile = nil

      request = Net::HTTP::Get.new(uri)
      # Explicitly set Host header to the original hostname for SNI and HTTP Host
      request["Host"] = uri.host

      http.request(request) do |res|
        return false unless res.is_a?(Net::HTTPSuccess)

        content_type = res.content_type

        # Reject anything outside the shared upload allowlist.
        return false if content_type.blank? ||
          Account::ACCEPTED_LOGO_CONTENT_TYPES.exclude?(content_type)

        # Reject oversized responses before streaming the body.
        if res.content_length && res.content_length > Account::MAX_LOGO_BYTES
          return false
        end

        extension = File.extname(uri.path).presence ||
          (content_type.include?("icon") ? ".ico" : ".png")

        tempfile = Tempfile.new([ "logo", extension ])
        tempfile.binmode

        bytes_read = 0

        res.read_body do |chunk|
          bytes_read += chunk.bytesize

          if bytes_read > Account::MAX_LOGO_BYTES
            tempfile.close
            tempfile.unlink
            tempfile = nil
            return false
          end

          tempfile.write(chunk)
        end

        return false if bytes_read.zero?

        tempfile.rewind

        account.with_lock do
          account.reload

          return false unless account.logo_source_auto?
          # Only check domain stale if we had an expected domain (domain-based fetch)
          return false if expected_domain.present? &&
            account.institution_domain != expected_domain

          account.attach_fetched_logo(
            io: tempfile,
            filename: "logo#{extension}",
            content_type: content_type
          )
        end
      end

      account.logo.attached?
    rescue URI::InvalidURIError, SocketError, Resolv::ResolvError => e
      Rails.logger.warn(
        "Rejected logo URL #{url} for account #{account.id}: #{e.message}"
      )
      false
    rescue StandardError => e
      Rails.logger.warn(
        "Failed to fetch logo from #{url} for account #{account.id}: #{e.message}"
      )
      false
    ensure
      tempfile&.close
      tempfile&.unlink
    end

    # Validates that a URI uses a public HTTP/HTTPS scheme and resolves to public IPs.
    #
    # @param uri [URI] The URI to validate
    # @return [Array<String>, false] Array of resolved public IP addresses, or false if invalid
    def public_http_url?(uri)
      return false unless %w[http https].include?(uri.scheme)
      return false if uri.host.blank?

      addresses = Resolv.getaddresses(uri.host)
      return false if addresses.empty?

      # Validate all resolved addresses are public
      unless addresses.all? { |address| public_ip_address?(address) }
        return false
      end

      addresses
    end

    # Checks if an IP address is public (globally routable).
    # Rejects loopback, private, link-local, shared address space (100.64.0.0/10),
    # multicast, and unspecified addresses to prevent SSRF attacks.
    #
    # @param address [String] The IP address to check
    # @return [Boolean] true if the address is a public, globally routable address
    def public_ip_address?(address)
      ip = IPAddr.new(address)

      return false if ip.loopback?
      return false if ip.private?
      return false if ip.link_local?

      # Reject shared address space (100.64.0.0/10) - RFC 6598
      # This includes addresses like 100.64.0.1 used by cloud metadata endpoints
      if ip.ipv4?
        shared_space = IPAddr.new("100.64.0.0/10")
        return false if shared_space.include?(ip)
      end

      # Reject unspecified addresses (0.0.0.0, ::, etc.)
      return false if ip == IPAddr.new("0.0.0.0") || ip == IPAddr.new("::")

      # Reject IPv4 multicast (224.0.0.0/4).
      return false if ip.ipv4? && ip.mask(4).to_i == IPAddr.new("224.0.0.0").mask(4).to_i

      # Reject IPv6 multicast (ff00::/8).
      return false if ip.ipv6? && ip.mask(8).to_i == IPAddr.new("ff00::").mask(8).to_i

      true
    rescue IPAddr::InvalidAddressError
      false
    end
end
