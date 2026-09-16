class ProviderMigrationControl < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  NATIVE_STATES = %w[active retired].freeze
  LEGACY_STATES = %w[legacy copying shadow failed].freeze

  encrypted_document :high_water_mark, :preparation_state

  belongs_to :family
  belongs_to :provider_connection, optional: true
  has_many :provider_migration_mappings, dependent: :restrict_with_error

  enum :state, { legacy: "legacy", copying: "copying", shadow: "shadow", quiescing: "quiescing", active: "active", rollback_pending: "rollback_pending", retired: "retired", failed: "failed" }, default: :legacy, validate: true

  validates :provider_key, :legacy_type, :legacy_id, presence: true
  validates :legacy_id, uniqueness: { scope: :legacy_type }
  validates :provider_connection_id, uniqueness: true, allow_nil: true
  validates :writer_epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :copy_version, numericality: { only_integer: true, greater_than: 0 }
  validate :connection_identity
  validate :stable_source

  # Retiring the compatibility data does not retire the shared connection.
  # Copy failures happen before cutover and leave the legacy writer in charge.
  def native_owned?
    NATIVE_STATES.include?(state)
  end

  def legacy_owned?
    LEGACY_STATES.include?(state)
  end

  private
    def connection_identity
      validate_family_of(provider_connection, :provider_connection)
      if provider_connection && provider_connection.provider_key != provider_key
        errors.add(:provider_key, "must match the provider connection")
      end
      validate_documents(:high_water_mark, :audit_results, :preparation_state)
      if lease_owner.nil? != lease_expires_at.nil?
        errors.add(:lease_owner, "and lease expiry must be set together")
      end
    end

    def stable_source
      return if new_record?

      %w[family_id provider_key legacy_type legacy_id].each do |attribute|
        errors.add(attribute, "cannot change") if will_save_change_to_attribute?(attribute)
      end
    end
end
