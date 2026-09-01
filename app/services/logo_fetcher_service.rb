# frozen_string_literal: true

require "net/http"
require "uri"

# Service to fetch and attach logos from URLs to accounts
class LogoFetcherService
  def initialize(account:, url:)
    @account = account
    @url = url
  end

  def fetch_and_attach
    return unless @url.present?

    # Download the image
    uri = URI.parse(@url)
    response = Net::HTTP.get_response(uri)

    return unless response.code == "200"

    # Create a tempfile with the image
    tempfile = Tempfile.new(["logo", File.extname(uri.path) || ".png"])
    tempfile.binmode
    tempfile.write(response.body)
    tempfile.rewind

    # Attach to account
    @account.logo.attach(
      io: tempfile,
      filename: "logo#{File.extname(uri.path) || '.png'}",
      content_type: response.content_type || "image/png"
    )

    # Ensure we mark as auto source since this was fetched automatically
    @account.logo_source = "auto"
  ensure
    tempfile&.close
    tempfile&.unlink
  end
end
