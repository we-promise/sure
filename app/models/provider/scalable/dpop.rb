require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"
require "time"
require "uri"

class Provider::Scalable
  module Dpop
    private

      def generate_dpop_key_pem
        OpenSSL::PKey::EC.generate("prime256v1").to_pem
      rescue OpenSSL::PKey::ECError
        raise Error.new(:provider_unavailable), cause: nil
      end

      def dpop_key(private_key_pem)
        key = OpenSSL::PKey.read(private_key_pem.to_s)
        unless key.is_a?(OpenSSL::PKey::EC) &&
            %w[prime256v1 secp256r1].include?(key.group.curve_name) &&
            key.private_key
          raise Error.new(:invalid_credentials)
        end

        key
      rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::ECError
        raise Error.new(:invalid_credentials), cause: nil
      end

      def dpop_public_jwk(private_key_pem)
        key = dpop_key(private_key_pem)
        point = key.public_key.to_octet_string(:uncompressed)
        unless point.bytesize == 65 && point.getbyte(0) == 4
          raise Error.new(:invalid_credentials)
        end

        {
          "kty" => "EC",
          "crv" => "P-256",
          "x" => Base64.urlsafe_encode64(point.byteslice(1, 32), padding: false),
          "y" => Base64.urlsafe_encode64(point.byteslice(33, 32), padding: false)
        }
      end

      def dpop_thumbprint(private_key_pem)
        jwk = dpop_public_jwk(private_key_pem)
        canonical = JSON.generate(
          "crv" => jwk.fetch("crv"),
          "kty" => jwk.fetch("kty"),
          "x" => jwk.fetch("x"),
          "y" => jwk.fetch("y")
        )
        Base64.urlsafe_encode64(Digest::SHA256.digest(canonical), padding: false)
      end

      def dpop_proof(private_key_pem, url, method:, nonce: nil, access_token: nil)
        uri = URI.parse(url)
        uri.query = nil
        uri.fragment = nil
        claims = {
          "htm" => method.to_s.upcase,
          "htu" => uri.to_s,
          "iat" => Time.now.to_i,
          "jti" => SecureRandom.urlsafe_base64(16, padding: false)
        }
        claims["nonce"] = nonce.to_s if nonce.present?
        claims["ath"] = Base64.urlsafe_encode64(Digest::SHA256.digest(access_token), padding: false) if access_token.present?

        JWT.encode(
          claims,
          dpop_key(private_key_pem),
          "ES256",
          { "typ" => "dpop+jwt", "jwk" => dpop_public_jwk(private_key_pem) }
        )
      rescue URI::InvalidURIError, JWT::EncodeError
        raise Error.new(:invalid_credentials), cause: nil
      end
  end
end
