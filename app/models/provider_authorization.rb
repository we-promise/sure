class ProviderAuthorization < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  encrypted_document :credentials

  belongs_to :family
  belongs_to :provider_connection
  has_many :provider_authorization_accounts, dependent: :destroy
  has_many :external_accounts, through: :provider_authorization_accounts
  has_many :ingestion_batches, dependent: :restrict_with_error
  has_many :provider_sync_checkpoints, dependent: :restrict_with_error

  enum :status, { active: "active", requires_update: "requires_update", revoked: "revoked" }, default: :active, validate: true

  before_validation :inherit_family
  validates :external_id, uniqueness: { scope: :provider_connection_id }, allow_nil: true
  validate :ownership_and_documents
  validate :stable_ownership

  def usable?
    active? && (expires_at.nil? || expires_at.future?)
  end

  private
    def inherit_family
      self.family_id ||= provider_connection&.family_id
    end

    def ownership_and_documents
      validate_family_of(provider_connection, :provider_connection)
      validate_documents(:credentials, :institution_metadata, :metadata)
    end

    def stable_ownership
      return if new_record?

      if will_save_change_to_provider_connection_id? || will_save_change_to_family_id?
        errors.add(:provider_connection, "cannot change ownership")
      end
    end
end
