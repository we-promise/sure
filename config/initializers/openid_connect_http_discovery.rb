# frozen_string_literal: true

# Patch: honor the issuer's scheme during OIDC discovery.
#
# The openid_connect/swd gems hardcode discovery to HTTPS (SWD.url_builder defaults to
# URI::HTTPS, and Config::Resource drops the issuer's scheme), so an http:// issuer -
# a self-hosted IdP without SSL - is upgraded to https:443 and fails to connect.
#
# Only the discovery request is affected: the endpoints it returns are absolute, and
# rack-oauth2 keeps a scheme that is already present, so the rest of the flow follows.
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
            @port = uri.port unless [ 80, 443 ].include?(uri.port)
            @path = File.join uri.path, ".well-known/openid-configuration"
            attr_missing!
          end

          def endpoint
            url_builder = @scheme == "http" ? URI::HTTP : URI::HTTPS
            url_builder.build [ nil, host, port, path, nil, nil ]
          rescue URI::Error => e
            raise SWD::Exception.new(e.message)
          end
        end
      end
    end
  end
end
