# frozen_string_literal: true

# Patch: honor the issuer's scheme during OIDC discovery.
#
# The openid_connect/swd gems hardcode discovery to HTTPS (SWD.url_builder defaults to
# URI::HTTPS, and Config::Resource drops the issuer's scheme), so an http:// issuer -
# a self-hosted IdP without SSL - is upgraded to https:443 and fails to connect.
#
# Only the discovery request is affected: the endpoints it returns are absolute, and
# rack-oauth2 keeps a scheme that is already present, so the rest of the flow follows.
# The port and cache-key handling below are also made scheme-aware so an http:// issuer
# never drops an explicit port or reuses an https:// issuer's cached metadata.
#
# Verified against openid_connect 2.3.1 / swd 2.0.3 - revisit if those are upgraded.
# See https://github.com/we-promise/sure/issues/2844.
require "openid_connect"

module OpenIDConnect
  module Discovery
    module Provider
      class Config
        class Resource
          def initialize(uri)
            @scheme = uri.scheme
            @host = uri.host
            # Only omit the scheme's own default port, so an explicitly configured
            # non-default port (e.g. http on 443, https on 80) is preserved.
            @port = uri.port unless uri.port == uri.default_port
            @path = File.join uri.path, ".well-known/openid-configuration"
            attr_missing!
          end

          def endpoint
            url_builder = @scheme == "http" ? URI::HTTP : URI::HTTPS
            url_builder.build [ nil, host, port, path, nil, nil ]
          rescue URI::Error => e
            raise SWD::Exception.new(e.message)
          end

          private

            # The gem keys the discovery cache on host alone. Now that a single host
            # can be reached over more than one scheme/port/path, include those so an
            # http:// issuer never reuses an https:// issuer's cached metadata.
            def cache_key
              digest = OpenSSL::Digest::SHA256.hexdigest [ @scheme, host, port, path ].join(" ")
              "swd:resource:opneid-conf:#{digest}"
            end
        end
      end
    end
  end
end
