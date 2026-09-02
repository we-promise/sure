# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"

class Account::LogoFetcher
  HTTP_TIMEOUT = 5

  # The fetcher builds request URLs from the domain the job was enqueued for
  # and refuses to attach when the account's domain has since changed, so a
  # stale response can never overwrite a newer fetch's result.
  def initialize(account, expected_domain: nil)
    @account = account
    @expected_domain = expected_domain
  end

  def fetch_and_attach
    return unless account.logo_source_auto?

    domain = (@expected_domain || account.institution_domain).presence
    return unless domain

    # Same priority as Account#logo_url: Brandfetch when configured, then the
    # linked provider's own logo (beats the generic favicon), then a favicon.
    # Stop at the first candidate that yields a usable image.
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
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      tempfile = nil

      http.request(Net::HTTP::Get.new(uri)) do |res|
        return false unless res.is_a?(Net::HTTPSuccess)

        content_type = res.content_type

        # Reject anything outside the shared upload allowlist — non-images as
        # well as image types Account's validation refuses — so the next
        # candidate still gets a chance.
        return false if content_type.blank? ||
          Account::ACCEPTED_LOGO_CONTENT_TYPES.exclude?(content_type)

        # Reject responses that advertise a size larger than the limit before
        # streaming the body into memory.
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

          # The domain may have changed while the request was in flight;
          # attaching the stale response would leave the wrong logo attached
          # until yet another fetch happens.
          return false if account.institution_domain != expected_domain

          account.attach_fetched_logo(
            io: tempfile,
            filename: "logo#{extension}",
            content_type: content_type
          )
        end
      end

      # Verify the attach actually landed; a silent failure must not stop the
      # fallback chain.
      account.logo.attached?
    rescue StandardError => e
      Rails.logger.warn("Failed to fetch logo from #{url} for account #{account.id}: #{e.message}")
      false
    ensure
      tempfile&.close
      tempfile&.unlink
    end
end
