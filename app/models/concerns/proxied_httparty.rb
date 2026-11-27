# frozen_string_literal: true

# HTTParty with Sure's outbound proxy decision. Include it in place of HTTParty: each
# connection resolves its proxy through ProxyConfigurable for the URL it actually opens, at
# request time, so redirects, per-request hosts and ENV changes are covered. Left to itself,
# HTTParty builds Net::HTTP.new(host, port), whose ENV lookup reads only HTTP_PROXY, even for
# an HTTPS target.
module ProxiedHttparty
  extend ActiveSupport::Concern

  included do
    include HTTParty
    connection_adapter ProxiedHttparty::ConnectionAdapter
  end

  # A request that sets :http_proxyaddr itself, even to nil, keeps its own choice. Otherwise
  # all four proxy options are set from the resolver: a proxy with its host, or all nil to go
  # direct, which also stops Net::HTTP's own ENV lookup.
  class ConnectionAdapter < HTTParty::ConnectionAdapter
    extend ProxyConfigurable

    PROXY_OPTIONS = %i[http_proxyaddr http_proxyport http_proxyuser http_proxypass].freeze

    def connection
      unless options.key?(:http_proxyaddr)
        @options = options.merge(PROXY_OPTIONS.zip(self.class.net_http_proxy_args(uri.to_s)).to_h)
      end

      super
    end
  end
end
