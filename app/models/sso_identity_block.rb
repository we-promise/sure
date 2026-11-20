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
    # Fails closed: while a stored legacy key cannot be read, the legacy
    # blocks it covers cannot be checked, so the identity counts as blocked.
    def blocked?(provider:, uid:)
      block, legacy_check_unavailable = lookup(provider: provider, uid: uid)
      block.present? || legacy_check_unavailable
    end

    def find_block(provider:, uid:)
      lookup(provider: provider, uid: uid).first
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

      # The digest is still written next to the encrypted uid so that the
      # previous release (an image rollback, or old processes during a
      # rolling deploy) keeps seeing new blocks. Drop it in a later release.
      def uid_attributes(uid)
        attributes = { uid_digest: digest(uid) }
        attributes[:uid] = uid.to_s if encryption_ready?
        attributes
      end

      # Returns the matching block and whether some legacy rows could not be
      # checked because their stored key is unreadable.
      def lookup(provider:, uid:)
        uid = uid.to_s
        if encryption_ready? && (block = find_by(provider: provider, uid: uid))
          return [ block, false ]
        end

        digested = where(provider: provider).where.not(uid_digest: nil)
        stored_keys, unreadable = stored_legacy_digest_keys(digested)
        stored_keys.each do |stored_key|
          block = digested.where.not(legacy_digest_key: nil).find_by(uid_digest: digest(uid, key: stored_key))
          return [ block, false ] if block
        end

        block = digested.find_by(legacy_digest_key: nil, uid_digest: digest(uid))
        [ block, block.nil? && unreadable ]
      end

      # Each row is read on its own, so one unreadable key (a row the rotation
      # backfill reported as failed) does not hide the readable ones.
      def stored_legacy_digest_keys(scope)
        unreadable = false
        keys = scope.where.not(legacy_digest_key: nil).select(:id, :legacy_digest_key).find_each.filter_map do |row|
          Base64.strict_decode64(row.legacy_digest_key)
        rescue ActiveRecord::Encryption::Errors::Base, ArgumentError => e
          Rails.logger.error("[SsoIdentityBlock] Stored legacy digest key of block #{row.id} is unreadable (#{e.class}); treating unmatched SSO logins for this provider as blocked")
          unreadable = true
          nil
        end
        [ keys.uniq, unreadable ]
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
