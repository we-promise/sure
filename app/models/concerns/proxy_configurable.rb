# frozen_string_literal: true

# Sure's one outbound proxy decision, for every HTTP client it builds itself. Left to
# itself, Net::HTTP reads only HTTP_PROXY, even for an HTTPS target, so a setup that sets
# only HTTPS_PROXY would send those calls direct.
#
# Usage (extend for class methods, as SslConfigurable):
#   class MyHttpClient
#     extend ProxyConfigurable
#
#     def connection(uri)
#       Net::HTTP.new(uri.host, uri.port, *self.class.net_http_proxy_args(uri.to_s))
#     end
#   end
#
# Only the two prefixed methods below are added to the extending class; the resolution
# helpers are private to this module, so they can't clash with the class's own methods.
module ProxyConfigurable
  PROXY_VARIABLES = %w[HTTPS_PROXY https_proxy HTTP_PROXY http_proxy].freeze

  # A proxy is configured but has no host Sure can read. Raised rather than going direct, so a
  # typo can't quietly route calls around the proxy. The message never carries the value.
  class InvalidProxyError < StandardError; end
  DIRECT = [ nil, nil, nil, nil ].freeze

  # The proxy URL for a request to `url`, or nil to go direct.
  def proxy_url_for(url, env: ENV) = ProxyConfigurable.url_for(url, env:)

  # Net::HTTP.new's four proxy arguments -- host, port, user, password -- for a request to
  # `url`: decoded as Net::HTTP's own lookup decodes them, or all nil to go direct. Passing
  # an explicit nil host also stops Net::HTTP's own ENV lookup.
  def net_http_proxy_args(url, env: ENV) = ProxyConfigurable.net_http_args(url, env:)

  class << self
    # HTTPS_PROXY, then HTTP_PROXY, whatever the target's scheme, so a setup that sets only
    # one still covers every call. Loopback is never proxied, as Ruby's own lookup does;
    # NO_PROXY matches a host exactly as written, so `127.0.0.1` doesn't cover `localhost`, and
    # `*` means every host, as curl reads it. A leading dot is dropped, as curl does, so
    # `.agents.example.com` covers `agents.example.com` itself as well as its subdomains.
    # A proxy without a scheme (`proxy.internal:8888`) is read as http://, as curl reads it;
    # one that still has no host raises InvalidProxyError.
    def url_for(url, env: ENV)
      target = parse(url)
      return if target&.host.blank? || loopback?(target.host)

      proxy = PROXY_VARIABLES.lazy.filter_map { env[_1].presence&.strip }.first
      return if proxy.nil?

      no_proxy = env["NO_PROXY"].presence || env["no_proxy"].presence
      no_proxy &&= no_proxy.split(",").map { _1.strip.delete_prefix(".") }.join(",")
      return if no_proxy && (no_proxy.strip == "*" || !URI::Generic.use_proxy?(target.host, address(target.host, no_proxy), target.port, no_proxy))

      proxy = "http://#{proxy}" unless proxy.match?(%r{\A[a-z][a-z\d+.-]*://}i)
      return proxy if parse(proxy)&.host.present?

      raise InvalidProxyError, "The outbound proxy URL cannot be read"
    end

    def net_http_args(url, env: ENV)
      proxy = url_for(url, env:)
      return DIRECT unless proxy

      uri = URI(proxy)
      [ uri.hostname, uri.port, uri.decoded_user.presence, uri.decoded_password.presence ]
    end

    private
      def parse(url)
        URI(url.to_s)
      rescue URI::InvalidURIError
        nil
      end

      # The host's address, for NO_PROXY's IP and CIDR entries, as Ruby's own lookup resolves
      # it (URI#find_proxy). Names are resolved only when NO_PROXY has such an entry.
      def address(host, no_proxy)
        return host if ip?(host.delete("[]"))
        return host unless no_proxy.split(",").any? { ip?(_1.strip) }

        IPSocket.getaddress(host)
      rescue SocketError
        host
      end

      def ip?(value) = IPAddr.new(value).present? rescue false

      def loopback?(host)
        host = host.delete_prefix("[").delete_suffix("]")
        host.casecmp?("localhost") || IPAddr.new(host).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end
  end
end
