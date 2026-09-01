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
    [ account.brandfetch_logo_url(domain), account.provider&.logo_url, account.favicon_url(domain) ].each do |url|
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

      response = http.request(Net::HTTP::Get.new(uri))
      return false unless response.is_a?(Net::HTTPSuccess) && response.body.present?

      content_type = response.content_type
      # A 200 with a non-image body (rate-limit page, interstitial) is not a
      # logo; reject it so the next candidate still gets a chance.
      return false if content_type.present? && !content_type.start_with?("image/")
      return false if response.body.bytesize > Account::MAX_LOGO_BYTES

      content_type ||= "image/png"
      extension = File.extname(uri.path).presence || (content_type.include?("icon") ? ".ico" : ".png")

      tempfile = Tempfile.new([ "logo", extension ])
      tempfile.binmode
      tempfile.write(response.body)
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

      true
    rescue StandardError => e
      Rails.logger.warn("Failed to fetch logo from #{url} for account #{account.id}: #{e.message}")
      false
    ensure
      tempfile&.close
      tempfile&.unlink
    end
end
