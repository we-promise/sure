class ProviderConnection < ApplicationRecord
  include Syncable, ProviderDataEncryption, ProviderDataOwnership

  encrypted_document :credentials, :credential_state

  belongs_to :family
  belongs_to :lease_sync, class_name: "Sync", optional: true
  has_many :provider_authorizations, dependent: :destroy
  has_many :external_accounts, dependent: :destroy
  has_many :account_providers, through: :external_accounts
  has_many :accounts, through: :account_providers
  has_many :ingestion_batches, dependent: :restrict_with_error
  has_many :provider_sync_generations, dependent: :restrict_with_error
  has_many :provider_sync_checkpoints, dependent: :destroy
  has_one :provider_migration_control, dependent: :restrict_with_error
  has_one_attached :logo, dependent: :purge_later

  enum :status, { good: "good", requires_update: "requires_update", disabled: "disabled" }, default: :good, validate: true

  scope :active, -> { where(scheduled_for_deletion: false).where.not(status: "disabled") }
  scope :syncable, -> {
    active.where(status: "good")
      .left_outer_joins(:provider_migration_control)
      .where("provider_migration_controls.id IS NULL OR provider_migration_controls.state IN (?)", ProviderMigrationControl::NATIVE_STATES)
  }
  scope :ordered, -> { order(created_at: :desc, id: :desc) }

  before_validation :advance_credential_revision
  validates :provider_key, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :name, presence: true
  validates :writer_epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :credential_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :identity_is_stable
  validate :documents_are_objects
  validate :lease_is_complete
  validate :credential_revision_is_monotonic

  # The connection name and displayed institution may change without changing its
  # ingestion identity. No request parameter is used to constantize a provider.
  def provider_name
    provider_key
  end

  def broadcast_sync_complete
    accounts.distinct.find_each(&:broadcast_sync_complete)
    family.broadcast_sync_complete
  end

  private
    def advance_credential_revision
      return if new_record? || !will_save_change_to_credentials?
      previous = credential_revision_in_database
      if credential_revision == previous
        self.credential_revision = previous + 1
      elsif credential_revision != previous + 1
        errors.add(:credential_revision, "must advance exactly once when credentials change")
      end
    end

    def credential_revision_is_monotonic
      return if new_record? || !credential_revision.is_a?(Integer)
      if credential_revision < credential_revision_in_database
        errors.add(:credential_revision, "cannot decrease")
      end
    end

    def syncer
      Provider::AccountData::Syncer.new(self)
    end

    def identity_is_stable
      return if new_record?

      errors.add(:provider_key, "cannot change") if will_save_change_to_provider_key?
      errors.add(:family_id, "cannot change") if will_save_change_to_family_id?
    end

    def documents_are_objects
      validate_documents(:credentials, :credential_state, :settings, :metadata)
    end

    def lease_is_complete
      errors.add(:lease_owner, "and lease expiry must be set together") if lease_owner.nil? != lease_expires_at.nil?
      if lease_sync_id && (lease_owner.nil? || lease_sync&.syncable_type != "ProviderConnection" || lease_sync&.syncable_id != id)
        errors.add(:lease_sync, "must own this connection lease")
      end
    end
end
