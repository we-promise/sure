class ProviderMigrationMapping < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  encrypted_document :preparation_state

  TARGETS = {
    "connection" => :provider_connection,
    "authorization" => :provider_authorization,
    "external_account" => :external_account
  }.freeze

  belongs_to :family
  belongs_to :provider_migration_control
  belongs_to :provider_connection, optional: true
  belongs_to :provider_authorization, optional: true
  belongs_to :external_account, optional: true

  before_validation :inherit_family
  validates :legacy_type, :legacy_id, presence: true
  validates :role, inclusion: { in: TARGETS.keys }
  validates :legacy_id, uniqueness: { scope: [ :legacy_type, :role ] }
  validate :target_matches_control
  validate :stable_mapping
  validate :stable_retained_owner

  def target
    public_send(TARGETS.fetch(role)) if TARGETS.key?(role)
  end

  private
    def stable_retained_owner
      if retained_owner.present? && !(retained_owner.is_a?(Hash) && retained_owner.keys.sort == Provider::AccountData::RetiredOwner::KEYS.sort)
        errors.add(:retained_owner, "must be a complete source ownership witness")
      end
      return if new_record? || attribute_in_database("retained_owner").nil?

      %w[retained_owner source_checksum source_version copied_at verified_at].each do |attribute|
        errors.add(attribute, "cannot change after retaining ownership") if will_save_change_to_attribute?(attribute)
      end
    end

    def inherit_family
      self.family_id ||= provider_migration_control&.family_id
    end

    def target_matches_control
      validate_documents(:preparation_state)
      validate_family_of(provider_migration_control, :provider_migration_control)
      populated = TARGETS.values.select { |association| public_send("#{association}_id").present? }
      errors.add(:role, "must identify exactly one matching target") unless populated == [ TARGETS[role] ]
      return unless target

      validate_family_of(target, TARGETS.fetch(role))
      connection = role == "connection" ? target : target.provider_connection
      control = provider_migration_control
      if control && (connection.nil? || connection.provider_key != control.provider_key ||
          (control.provider_connection_id && connection.id != control.provider_connection_id))
        errors.add(:role, "target must belong to the migration's provider connection")
      end
    end

    def stable_mapping
      return if new_record?

      %w[family_id provider_migration_control_id legacy_type legacy_id role provider_connection_id provider_authorization_id external_account_id].each do |attribute|
        errors.add(attribute, "cannot change") if will_save_change_to_attribute?(attribute)
      end
    end
end
