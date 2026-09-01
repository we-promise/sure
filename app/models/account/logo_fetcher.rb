# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"

class Account::LogoFetcher
  HTTP_TIMEOUT = 5

  def initialize(account)
    @account = account
  end

  def fetch_and_attach
    return unless account.logo_source_auto?
    return unless account.institution_domain.present?

    # Same priority as Account#logo_url: Brandfetch when configured, then the
    # linked provider's own logo (beats the generic favicon), then a favicon.
    # Stop at the first candidate that yields a usable image.
    [ account.brandfetch_logo_url, account.provider&.logo_url, account.favicon_url ].each do |url|
      next if url.blank?
      return if fetch_from_url(url)
    end
  end

  private
    attr_reader :account

    def fetch_from_url(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      response = http.request(Net::HTTP::Get.new(uri))
      return false unless response.is_a?(Net::HTTPSuccess) && response.body.present?

      content_type = response.content_type || "image/png"
      extension = File.extname(uri.path).presence || (content_type.include?("icon") ? ".ico" : ".png")

      tempfile = Tempfile.new([ "logo", extension ])
      tempfile.binmode
      tempfile.write(response.body)
      tempfile.rewind

      account.with_lock do
        account.reload
        return false unless account.logo_source_auto?

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
