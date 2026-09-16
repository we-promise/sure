# Shared provider storage never falls back to plaintext. Legacy models keep their
# optional Encryptable behavior until their explicit migration has passed preflight.
module ProviderDataEncryption
  extend ActiveSupport::Concern

  included do
    include Encryptable
    validate :provider_data_encryption_available
  end

  class_methods do
    def encryption_ready?
      ActiveRecordEncryptionConfig.ready?
    end

    def encrypted_document(*attributes)
      attributes.each do |attribute|
        serialize attribute, coder: JSON, type: Hash
        encrypts attribute
      end
    end
  end

  private
    def provider_data_encryption_available
      return if ActiveRecordEncryptionConfig.ready?

      errors.add(:base, "Active Record encryption must be configured before storing provider data")
    end
end
