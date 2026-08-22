# frozen_string_literal: true

class SsoIdentityBlock < ApplicationRecord
  include Encryptable

  encrypts :identity_label if encryption_ready?

  validates :provider, :uid_digest, :identity_label, presence: true
  validates :uid_digest, uniqueness: { scope: :provider }

  class << self
    def blocked?(provider:, uid:)
      exists?(provider: provider, uid_digest: digest(uid))
    end

    def block_all!(identities, identity_label:)
      identities.find_each do |identity|
        find_or_create_by!(
          provider: identity.provider,
          uid_digest: digest(identity.uid)
        ) { |block| block.identity_label = identity_label }
      end
    end

    private

      def digest(uid)
        Digest::SHA256.hexdigest(uid.to_s)
      end
  end
end
