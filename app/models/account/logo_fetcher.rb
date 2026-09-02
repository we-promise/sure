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
  def initialize(account, expected_domain: nil)
    @account = account
    @expected_domain = expected_domain
  end

  def fetch_and_attach
    return unless account.logo_source_auto?

    domain = (@expected_domain || account.institution_domain).presence
    return unless domain

    # Do not make any network request if the domain changed while the job
    # was waiting in the queue.
    return if @expected_domain.present? &&
      account.institution_domain != @expected_domain

    # Same priority as Account#logo_url: Brandfetch when configured, then the
    # linked provider's own logo, then a favicon.
    [
      account.brandfetch_logo_url(domain),
      account.provider&.logo_url,
      account.favicon_url(domain)
    ].each do |url|
      next if url.blank?
      return if fetch_from_url(url, domain)
    end
  end

  private

    attr_reader :account

    def fetch_from_url(url, expected_domain)
      uri = URI.parse(url)

      return false unless public_http_url?(uri)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      tempfile = nil

      http.request(Net::HTTP::Get.new(uri)) do |res|
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
          return false if account.institution_domain != expected_domain

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

    def public_http_url?(uri)
      return false unless %w[http https].include?(uri.scheme)
      return false if uri.host.blank?

      addresses = Resolv.getaddresses(uri.host)
      return false if addresses.empty?

      addresses.all? { |address| public_ip_address?(address) }
    end

    def public_ip_address?(address)
      ip = IPAddr.new(address)

      return false if ip.loopback?
      return false if ip.private?
      return false if ip.link_local?

      # Reject IPv4 multicast (224.0.0.0/4).
      return false if ip.ipv4? && ip.mask(4).to_i == IPAddr.new("224.0.0.0").mask(4).to_i

      # Reject IPv6 multicast (ff00::/8).
      return false if ip.ipv6? && ip.mask(8).to_i == IPAddr.new("ff00::").mask(8).to_i

      true
    rescue IPAddr::InvalidAddressError
      false
    end
end
