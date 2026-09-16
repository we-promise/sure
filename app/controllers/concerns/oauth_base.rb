module OauthBase
  extend ActiveSupport::Concern

  class << self
    # The scopes Doorkeeper is actually configured with
    # (config/initializers/doorkeeper.rb: default_scopes :read,
    # optional_scopes :read_write), derived once here instead of repeated as
    # a literal in every controller that needs the list — so a future change
    # to that config can't silently drift out of sync with MCP's read/read_write
    # semantics.
    def mcp_scopes
      @mcp_scopes ||= Doorkeeper.configuration.scopes.to_a.freeze
    end
  end

  private
    def configured_base_url
      (ENV["APP_URL"].presence || request.base_url).chomp("/")
    end
end
