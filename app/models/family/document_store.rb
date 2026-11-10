# A hosted store belongs to one family and one credential context. Old contexts
# remain recorded after key rotation; their credentials are not retained here.
class Family::DocumentStore < ApplicationRecord
  self.table_name = "family_document_stores"
  self.filter_attributes += [ :credential_fingerprint ]

  belongs_to :family
  has_many :family_documents, foreign_key: :family_document_store_id, dependent: :restrict_with_error

  validates :provider, inclusion: { in: %w[openai] }
  validates :credential_fingerprint, presence: true
  validate :ownership_cannot_change, on: :update

  def self.fingerprint(family_id:, provider:, api_key:)
    key = Rails.application.key_generator.generate_key("family_document_store_credentials", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, [ family_id, provider, api_key ].join("\0"))
  end

  def serializable_hash(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + [ "credential_fingerprint" ]
    options[:methods] = Array(options[:methods]).reject { |name| name.to_s == "credential_fingerprint" } if options[:methods]
    super(options).except("credential_fingerprint")
  end

  private
    def ownership_cannot_change
      if will_save_change_to_family_id? || will_save_change_to_provider? || will_save_change_to_credential_fingerprint? ||
          (provider_store_id_in_database.present? && will_save_change_to_provider_store_id?)
        errors.add(:base, "Document store ownership cannot change")
      end
    end
end
