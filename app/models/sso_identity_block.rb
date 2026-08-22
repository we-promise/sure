# frozen_string_literal: true

class SsoIdentityBlock < ApplicationRecord
  include Encryptable

  class BlockedIdentity < StandardError; end

  encrypts :identity_label if encryption_ready?

  before_validation :redact_identity_label_unless_encrypted

  validates :provider, :uid_digest, :identity_label, presence: true
  validates :uid_digest, uniqueness: { scope: :provider }

  class << self
    def blocked?(provider:, uid:)
      exists?(provider: provider, uid_digest: digest(uid))
    end

    def block_all!(identities, identity_label:)
      identities.find_each do |identity|
        with_identity_lock(provider: identity.provider, uid: identity.uid) do
          find_or_create_by!(
            provider: identity.provider,
            uid_digest: digest(identity.uid)
          ) { |block| block.identity_label = identity_label }
        end
      end
    end

    def with_identity_lock(provider:, uid:)
      transaction do
        lock_key = advisory_lock_key(provider: provider, uid: uid)
        connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", lock_key ]))
        yield
      end
    end

    def digest(uid)
      OpenSSL::HMAC.hexdigest("SHA256", digest_key, uid.to_s)
    end

    private

      def digest_key
        Rails.application.key_generator.generate_key("sso_identity_block_uid", 32)
      end

      def advisory_lock_key(provider:, uid:)
        OpenSSL::HMAC.digest("SHA256", digest_key, "#{provider}\0#{uid}").unpack1("q>")
      end
  end

  private

    def redact_identity_label_unless_encrypted
      return if self.class.encryption_ready?

      self.identity_label = "Removed identity #{uid_digest.to_s.first(12)}"
    end
end
