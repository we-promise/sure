# frozen_string_literal: true

class SsoIdentityBlock < ApplicationRecord
  include Encryptable

  class BlockedIdentity < StandardError; end

  # Salt of the HMAC key derived from SECRET_KEY_BASE. Only used for blocks
  # stored as a digest: those from before the uid was encrypted, and new ones
  # while Active Record encryption is not configured.
  LEGACY_DIGEST_SALT = "sso_identity_block_uid"

  if encryption_ready?
    encrypts :identity_label
    # Encrypted (not hashed with a key of our own) so a key rotation re-encrypts
    # it with every other column instead of silently lifting the block.
    encrypts :uid, deterministic: true
    # The HMAC key a legacy uid_digest was made with, so the digest still
    # matches after SECRET_KEY_BASE changes.
    encrypts :legacy_digest_key
  end

  before_validation :redact_identity_label_unless_encrypted

  validates :provider, :identity_label, presence: true
  validates :uid, uniqueness: { scope: :provider }, allow_nil: true
  validates :uid_digest, uniqueness: { scope: :provider }, allow_nil: true
  validate :uid_or_digest_present

  class << self
    def blocked?(provider:, uid:)
      find_block(provider: provider, uid: uid).present?
    end

    def find_block(provider:, uid:)
      uid = uid.to_s
      (encryption_ready? && find_by(provider: provider, uid: uid)) || find_by_digest(provider: provider, uid: uid)
    end

    def block_all!(identities, identity_label:)
      identities.find_each do |identity|
        with_identity_lock(provider: identity.provider, uid: identity.uid) do
          next if find_block(provider: identity.provider, uid: identity.uid)

          create!(provider: identity.provider, identity_label: identity_label, **uid_attributes(identity.uid))
        end
      end
    end

    def with_identity_lock(provider:, uid:)
      transaction do
        lock_key = OpenSSL::HMAC.digest("SHA256", derived_digest_key, "#{provider}\0#{uid}").unpack1("q>")
        connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", lock_key ]))
        yield
      end
    end

    def digest(uid, key: derived_digest_key)
      OpenSSL::HMAC.hexdigest("SHA256", key, uid.to_s)
    end

    private

      def uid_attributes(uid)
        encryption_ready? ? { uid: uid.to_s } : { uid_digest: digest(uid) }
      end

      def find_by_digest(provider:, uid:)
        digested = where(provider: provider).where.not(uid_digest: nil)

        # The migration stores the same key with every legacy row, so one
        # decrypted copy covers all of them.
        if (stored_key = stored_legacy_digest_key(digested))
          block = digested.where.not(legacy_digest_key: nil).find_by(uid_digest: digest(uid, key: stored_key))
          return block if block
        end

        digested.find_by(legacy_digest_key: nil, uid_digest: digest(uid))
      end

      # A key that no longer decrypts (a row the rotation backfill reported as
      # failed) must not turn every SSO login into an error.
      def stored_legacy_digest_key(scope)
        encoded = scope.where.not(legacy_digest_key: nil).pick(:legacy_digest_key)
        encoded && Base64.strict_decode64(encoded)
      rescue ActiveRecord::Encryption::Errors::Base, ArgumentError => e
        Rails.logger.error("[SsoIdentityBlock] Stored legacy digest key is unreadable (#{e.class}); legacy blocks cannot be checked")
        nil
      end

      def derived_digest_key
        Rails.application.key_generator.generate_key(LEGACY_DIGEST_SALT, 32)
      end
  end

  private

    def redact_identity_label_unless_encrypted
      return if self.class.encryption_ready?

      self.identity_label = "Removed identity #{uid_digest.to_s.first(12)}"
    end

    def uid_or_digest_present
      errors.add(:uid, :blank) if uid.blank? && uid_digest.blank?
    end
end
