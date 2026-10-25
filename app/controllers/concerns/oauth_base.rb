module OauthBase
  extend ActiveSupport::Concern

  # Scope required by /mcp; discovery metadata and challenges must advertise the same value.
  MCP_SCOPE = "read_write"

  private
    def configured_base_url
      (ENV["APP_URL"].presence || request.base_url).chomp("/")
    end
end
