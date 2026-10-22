class Provider::Simplefin
  # Pending: some institutions do not return pending transactions even with `pending=1`.
  # This is provider variability (not a bug). The importer resolves pending inclusion
  # from its explicit argument, SIMPLEFIN_INCLUDE_PENDING, or Setting.syncs_include_pending
  # (default-on without overrides), then passes pending: to this client.
  # SIMPLEFIN_DEBUG_RAW=1 enables raw payload logging (default-off); environment
  # configuration lives in config/initializers/simplefin.rb.
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance SimpleFin Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  # Retry configuration for transient network failures
  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2 # seconds
  MAX_RETRY_DELAY = 30 # seconds

  # Errors that are safe to retry (transient network issues)
  RETRYABLE_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    EOFError
  ].freeze

  # Address ranges for the SimpleFIN URL check (see ensure_allowed_url!).
  # Always blocked besides link-local: unspecified, multicast and reserved
  # addresses, and cloud metadata endpoints outside the link-local range
  # (AWS IPv6 in fc00::/7, Alibaba Cloud in the CGNAT range).
  ALWAYS_BLOCKED_NETWORKS = %w[
    0.0.0.0/8 224.0.0.0/4 240.0.0.0/4 ::/128 ff00::/8
    fd00:ec2::254/128 100.100.100.200/32
  ].map { |range| IPAddr.new(range) }.freeze
  # Blocked on managed instances besides loopback and private ranges:
  # carrier-grade NAT, IETF protocol assignments and benchmarking ranges.
  MANAGED_BLOCKED_NETWORKS = %w[100.64.0.0/10 192.0.0.0/24 198.18.0.0/15].map { |range| IPAddr.new(range) }.freeze

  # Connects to the address that ensure_allowed_url! checked instead of
  # resolving the host a second time, so DNS rebinding cannot swap in an
  # internal address. TLS (SNI, certificate) and the Host header still use
  # the hostname. Through an HTTP proxy, https requests are pinned too
  # (Net::HTTP sends CONNECT to the pinned address); plain http requests
  # skip the proxy (see guarded_request_options).
  class PinnedConnectionAdapter < HTTParty::ConnectionAdapter
    def connection
      http = super
      pinned_address = options.dig(:connection_adapter_options, :ipaddr)
      http.ipaddr = pinned_address if pinned_address
      http
    end
  end

  def initialize
  end

  # Checks a setup token's claim URL without claiming it, so callers that
  # claim later (in a job) can reject a bad token right away.
  def validate_setup_token!(setup_token)
    ensure_allowed_url!(Base64.decode64(setup_token))
    nil
  rescue SocketError
    raise SimplefinError.new("SimpleFIN host could not be resolved", :network_error)
  end

  def claim_access_url(setup_token)
    # Decode the base64 setup token to get the claim URL
    claim_url = Base64.decode64(setup_token)

    # Use retry logic for transient network failures during token claim
    # Claim should be fast; keep request-path latency bounded.
    # Use self.class.post to inherit class-level SSL and timeout defaults.
    # The setup token is user input, so it must not point the server at
    # internal services (cloud metadata, localhost, private networks).
    response = with_retries("POST /claim", max_retries: 1, backoff: false) do |attempt|
      self.class.post(claim_url, timeout: 15, **guarded_request_options(claim_url, attempt: attempt))
    end

    case response.code
    when 200
      # The response body contains the access URL with embedded credentials.
      # It comes from the same untrusted bridge. The token is used up now, so
      # only check what needs no DNS lookup; a transient lookup failure must not
      # lose the URL. get_accounts runs the full check before every request.
      access_url = response.body.strip
      ensure_allowed_url!(access_url, resolve: false)
      access_url
    when 403
      raise SimplefinError.new("Setup token may be compromised, expired, or already used", :token_compromised)
    else
      raise SimplefinError.new("Failed to claim access URL: #{response.code} #{response.message}", :claim_failed)
    end
  end

  def get_accounts(access_url, start_date: nil, end_date: nil, pending: nil)
    # Build query parameters
    query_params = { "version" => "2" }

    # SimpleFin expects Unix timestamps for dates
    if start_date
      start_timestamp = start_date.to_time.to_i
      query_params["start-date"] = start_timestamp.to_s
    end

    if end_date
      end_timestamp = end_date.to_time.to_i
      query_params["end-date"] = end_timestamp.to_s
    end

    # Per the SimpleFIN protocol, pending transactions are excluded by default
    # and only included when `pending=1` is present. Bridges presence-check the
    # param, so sending `pending=0` behaves like `pending=1` — the only
    # spec-compliant way to exclude pending is to omit the param entirely.
    query_params["pending"] = "1" if pending

    accounts_url = "#{access_url}/accounts"
    accounts_url += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?

    # The access URL already contains HTTP Basic Auth credentials
    # Use retry logic with exponential backoff for transient network failures
    # Use self.class.get to inherit class-level SSL and timeout defaults
    # The stored access URL came from the bridge; re-check it on every request.
    response = with_retries("GET /accounts") do |attempt|
      self.class.get(accounts_url, **guarded_request_options(access_url, attempt: attempt))
    end

    case response.code
    when 200
      JSON.parse(response.body, symbolize_names: true)
    when 400
      Rails.logger.error "SimpleFin API: Bad request - #{response.body}"
      raise SimplefinError.new("Bad request to SimpleFin API", :bad_request)
    when 403
      raise SimplefinError.new("Access URL is no longer valid", :access_forbidden)
    when 402
      raise SimplefinError.new("Payment required to access this account", :payment_required)
    when 429
      Rails.logger.warn "SimpleFin API: Rate limited - #{response.body}"
      raise SimplefinError.new("SimpleFin rate limit exceeded. Please try again later.", :rate_limited)
    when 500..599
      Rails.logger.error "SimpleFin API: Server error - Code: #{response.code}, Body: #{response.body}"
      raise SimplefinError.new("SimpleFin server error (#{response.code}). Please try again later.", :server_error)
    else
      Rails.logger.error "SimpleFin API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
      raise SimplefinError.new("Failed to fetch accounts: #{response.code} #{response.message}", :fetch_failed)
    end
  end

  def get_info(base_url)
    # Use self.class.get to inherit class-level SSL and timeout defaults
    response = self.class.get("#{base_url}/info", **guarded_request_options(base_url))

    case response.code
    when 200
      response.body.strip.split("\n")
    else
      raise SimplefinError.new("Failed to get server info: #{response.code} #{response.message}", :info_failed)
    end
  end

  class SimplefinError < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  private
    # Checks the URL, then pins the connection to one of the checked
    # addresses; each retry moves on to the next one, like the resolver
    # fallback of an unpinned connection. No redirects: a redirect target
    # would bypass the check. A proxy would resolve a plain http host itself,
    # so plain http (self-hosted only) connects directly.
    def guarded_request_options(url, attempt: 0)
      addresses = ensure_allowed_url!(url)
      options = {
        follow_redirects: false,
        connection_adapter: PinnedConnectionAdapter,
        connection_adapter_options: { ipaddr: addresses[attempt % addresses.size] }
      }
      options[:http_proxyaddr] = nil if URI.parse(url.to_s).scheme == "http"
      options
    end

    # Link-local covers cloud metadata endpoints (169.254.169.254) and is
    # never a valid bridge address. Managed instances additionally block
    # loopback and private networks; self-hosters may run a bridge on their
    # own network, so those stay allowed there.
    #
    # Returns the checked addresses, IPv4 first. With resolve: false only an
    # IP literal host is checked. A failed lookup raises SocketError, so
    # with_retries retries it and reports :network_error, not :invalid_url.
    def ensure_allowed_url!(url, resolve: true)
      uri = URI.parse(url.to_s)
      raise SimplefinError.new("SimpleFIN URL must use http or https", :invalid_url) unless uri.is_a?(URI::HTTP) && uri.host.present?
      raise SimplefinError.new("SimpleFIN URL must use https", :invalid_url) if managed_mode? && uri.scheme != "https"

      addresses = resolve ? resolve_addresses(uri.hostname) : ip_literal_addresses(uri.hostname)
      raise SocketError, "SimpleFIN host could not be resolved" if resolve && addresses.empty?

      if addresses.any? { |address| disallowed_address?(address) }
        raise SimplefinError.new("SimpleFIN URL points to a disallowed network address", :invalid_url)
      end

      # IPv4-mapped IPv6 addresses connect as plain IPv4. Prefer IPv4: many
      # self-hosted Docker setups have no IPv6 route.
      addresses.map { |address| normalize_address(address) }.uniq
        .sort_by.with_index { |address, index| [ IPAddr.new(address).ipv4? ? 0 : 1, index ] }
    rescue URI::InvalidURIError
      raise SimplefinError.new("SimpleFIN URL is invalid", :invalid_url)
    end

    # Uses the system resolver, like the HTTP request itself (mDNS, hosts file).
    def resolve_addresses(host)
      Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq
    end

    def normalize_address(address)
      ip = IPAddr.new(address)
      ip.ipv4_mapped? ? ip.native.to_s : address
    end

    def ip_literal_addresses(host)
      IPAddr.new(host)
      [ host ]
    rescue IPAddr::InvalidAddressError
      []
    end

    def disallowed_address?(address)
      ip = embedded_ipv4(IPAddr.new(address))
      return true if ip.link_local? || ALWAYS_BLOCKED_NETWORKS.any? { |network| network.include?(ip) }
      return false unless managed_mode?

      ip.loopback? || ip.private? || MANAGED_BLOCKED_NETWORKS.any? { |network| network.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    # IPv4-mapped, IPv4-compatible, NAT64 and 6to4 addresses reach the IPv4
    # address they carry, so they are checked as that address.
    def embedded_ipv4(ip)
      NetworkAddress.embedded_ipv4(ip)
    end

    def managed_mode?
      Rails.application.config.app_mode.managed?
    end

    # Execute a block with retry logic and exponential backoff for transient network errors.
    # This helps handle temporary network issues that cause autosync failures while
    # manual sync (with user retry) succeeds.
    def with_retries(operation_name, max_retries: MAX_RETRIES, backoff: true)
      retries = 0

      begin
        yield retries
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "SimpleFin API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay) if backoff && delay.to_f.positive?
          retry
        else
          Rails.logger.error(
            "SimpleFin API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise SimplefinError.new(
            "Network error after #{max_retries} retries: #{e.message}",
            :network_error
          )
        end
      rescue SimplefinError => e
        # Preserve original error type and message.
        raise
      rescue => e
        # Non-retryable errors are logged and re-raised immediately
        Rails.logger.error "SimpleFin API: #{operation_name} failed with non-retryable error: #{e.class}: #{e.message}"
        raise SimplefinError.new("Exception during #{operation_name}: #{e.message}", :request_failed)
      end
    end

    # Calculate delay with exponential backoff and jitter
    def calculate_retry_delay(retry_count)
      # Exponential backoff: 2^retry * initial_delay
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      # Add jitter (0-25% of base delay) to prevent thundering herd
      jitter = base_delay * rand * 0.25
      # Cap at max delay
      [ base_delay + jitter, MAX_RETRY_DELAY ].min
    end
end
