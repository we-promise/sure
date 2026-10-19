require "base64"
require "jwt"
require "time"

class Provider::Scalable
  module TokenVerifier
    OIDC_DISCOVERY_URL = "https://secure.scalable.capital/.well-known/openid-configuration".freeze
    OIDC_DISCOVERY_ISSUER = "https://secure.scalable.capital".freeze
    OIDC_JWKS_PATH = "/.well-known/jwks.json".freeze
    TOKEN_CLOCK_SKEW_SECONDS = 60
    JWKS_CACHE_SECONDS = 300

    PERSON_ID_CLAIMS = [
      "https://de.scalable.capital/person_id",
      "https://de.scalable.capital/personId",
      "person_id"
    ].freeze
    SESSION_ID_CLAIMS = [
      "https://de.scalable.capital/session_id",
      "session_id"
    ].freeze

    private

      def verify_access_token!(token, private_key_pem:, allow_expired: false)
        untrusted_payload, header = JWT.decode(token.to_s, nil, false)
        raise Error.new(:token_invalid) unless header["alg"] == "RS256"

        kid = header["kid"].to_s.strip
        raise Error.new(:token_invalid) if kid.empty?

        jwk = signing_jwks.find { |candidate| candidate["kid"] == kid }
        raise Error.new(:token_invalid) unless jwk.is_a?(Hash)
        raise Error.new(:token_invalid) unless jwk["kty"] == "RSA"
        raise Error.new(:token_invalid) if jwk["use"] && jwk["use"] != "sig"
        raise Error.new(:token_invalid) if jwk["alg"] && jwk["alg"] != "RS256"
        raise Error.new(:token_invalid) if jwk["n"].blank? || jwk["e"].blank?

        public_key = JWT::JWK::RSA.import(
          "kty" => "RSA",
          "n" => jwk["n"],
          "e" => jwk["e"]
        ).public_key
        claims, = JWT.decode(
          token.to_s,
          public_key,
          true,
          algorithms: [ "RS256" ],
          verify_expiration: false,
          verify_not_before: false,
          verify_iat: false,
          verify_aud: false,
          verify_iss: false
        )

        validate_token_claims!(claims, allow_expired: allow_expired, private_key_pem: private_key_pem)
      rescue Error
        raise
      rescue JWT::DecodeError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError, KeyError
        raise Error.new(:token_invalid), cause: nil
      end

      def validate_token_claims!(claims, allow_expired:, private_key_pem:)
        issuer = normalized_issuer(claims["iss"])
        raise Error.new(:token_invalid) unless issuer == OIDC_DISCOVERY_ISSUER

        audience = claims["aud"]
        audiences = case audience
        when String
          [ audience ]
        when Array
          raise Error.new(:token_invalid) if audience.empty? || audience.any? { |value| !value.is_a?(String) }
          audience
        else
          raise Error.new(:token_invalid)
        end
        raise Error.new(:token_invalid) unless audiences.include?(AUDIENCE)

        if audiences.length > 1
          raise Error.new(:token_invalid) unless claims["azp"] == CLIENT_ID
        end

        exp = claims["exp"]
        raise Error.new(:token_invalid) unless exp.is_a?(Integer)
        now = Time.now.to_i
        if !allow_expired && now > exp + TOKEN_CLOCK_SKEW_SECONDS
          raise Error.new(:token_invalid)
        end

        nbf = optional_integer_claim!(claims, "nbf")
        raise Error.new(:token_invalid) if nbf && now + TOKEN_CLOCK_SKEW_SECONDS < nbf
        iat = optional_integer_claim!(claims, "iat")
        raise Error.new(:token_invalid) if iat && iat > now + TOKEN_CLOCK_SKEW_SECONDS

        person_id = PERSON_ID_CLAIMS.filter_map do |name|
          value = claims[name]
          value.strip if value.is_a?(String) && !value.strip.empty?
        end.first
        raise Error.new(:token_invalid) if person_id.blank?

        session_id = SESSION_ID_CLAIMS.filter_map do |name|
          value = claims[name]
          value.strip if value.is_a?(String) && !value.strip.empty?
        end.first

        validate_dpop_binding!(claims, private_key_pem)

        {
          "person_id" => person_id,
          "session_id" => session_id,
          "exp" => exp
        }
      end

      def validate_dpop_binding!(claims, private_key_pem)
        return unless claims.key?("cnf")

        confirmation = claims["cnf"]
        raise Error.new(:token_invalid) unless confirmation.is_a?(Hash)

        jkt = confirmation["jkt"]
        raise Error.new(:token_invalid) unless jkt.is_a?(String) && !jkt.strip.empty?
        raise Error.new(:token_invalid) unless ActiveSupport::SecurityUtils.secure_compare(
          jkt,
          dpop_thumbprint(private_key_pem)
        )
      end

      def optional_integer_claim!(claims, name)
        return nil unless claims.key?(name)

        value = claims[name]
        raise Error.new(:token_invalid) unless value.is_a?(Integer)

        value
      end

      def signing_jwks
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cache = @scalable_jwks_cache
        return cache[:keys] if cache && cache[:expires_at] > now

        @scalable_jwks_cache_mutex ||= Mutex.new
        @scalable_jwks_cache_mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          cache = @scalable_jwks_cache
          return cache[:keys] if cache && cache[:expires_at] > now

          discovery = get_json(OIDC_DISCOVERY_URL, allowed_hosts: [ AUTH_HOST ])
          raise Error.new(:token_invalid) unless normalized_issuer(discovery["issuer"]) == OIDC_DISCOVERY_ISSUER

          jwks_url = discovery["jwks_uri"].to_s
          jwks_uri = validate_https_uri!(jwks_url, allowed_hosts: [ AUTH_HOST ])
          unless jwks_uri.path == OIDC_JWKS_PATH && jwks_uri.query.nil?
            raise Error.new(:token_invalid)
          end

          jwks = get_json(jwks_uri.to_s, allowed_hosts: [ AUTH_HOST ])
          keys = jwks["keys"]
          raise Error.new(:token_invalid) unless keys.is_a?(Array) && keys.present?
          raise Error.new(:token_invalid) unless keys.all? { |candidate| candidate.is_a?(Hash) }

          @scalable_jwks_cache = {
            keys: keys,
            expires_at: now + JWKS_CACHE_SECONDS
          }
          keys
        end
      end

      def get_json(url, allowed_hosts:)
        response = http_request(url, method: :get, allowed_hosts: allowed_hosts)
        reject_redirect!(response)
        json_response!(response)
      end

      def normalized_issuer(value)
        return "" unless value.is_a?(String)

        value.strip.sub(%r{/+\z}, "")
      end
  end
end
