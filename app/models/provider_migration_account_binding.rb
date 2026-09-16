# Reverse ownership for one immutable, checksummed legacy account archive.
# Historical financial/link UUIDs survive deletion and are never live authority.
class ProviderMigrationAccountBinding < ApplicationRecord
  MAX_CHUNKS = 1_024
  CHECKSUM = /\Av1-[0-9a-f]{64}\z/
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  belongs_to :family
  belongs_to :provider_migration_mapping
  belongs_to :first_batch, class_name: "IngestionBatch"

  enum :binding_state, { linked: "linked", unlinked: "unlinked" }, validate: true
  validates :source_checksum, format: { with: CHECKSUM }, uniqueness: { scope: :provider_migration_mapping_id }
  validates :first_batch_id, uniqueness: true
  validates :chunk_count, numericality: { only_integer: true, in: 1..MAX_CHUNKS }
  validates :financial_account_id, :account_provider_id, format: { with: UUID }, allow_nil: true
  validate :binding_shape
  validate :archive_ownership
  validate :immutable_receipt, on: :update

  private
    def binding_shape
      valid = linked? ? financial_account_id.present? && account_provider_id.present? :
        unlinked? && financial_account_id.nil? && account_provider_id.nil?
      errors.add(:binding_state, "must describe the captured linked or unlinked identity") unless valid
    end

    def archive_ownership
      mapping = provider_migration_mapping
      batch = first_batch
      return unless mapping && batch

      control = ProviderMigrationControl.where(id: mapping.provider_migration_control_id)
        .select(:id, :family_id, :provider_key, :provider_connection_id).first
      external = ExternalAccount.where(id: mapping.external_account_id)
        .select(:id, :family_id, :provider_key, :provider_connection_id).first
      unless mapping.role == "external_account" && mapping.family_id == family_id &&
          control && control.family_id == family_id && external && external.family_id == family_id &&
          external.provider_key == control.provider_key && external.provider_connection_id == control.provider_connection_id &&
          batch.family_id == family_id && batch.provider_connection_id == control.provider_connection_id &&
          batch.external_account_id == mapping.external_account_id && batch.origin_kind == "migration" &&
          batch.stream == "legacy_snapshot" && batch.sequence == 0 &&
          batch.scope_key == "#{mapping.legacy_type}:#{mapping.legacy_id}" &&
          batch.idempotency_key == "migration:#{control.id}:#{mapping.legacy_type}:#{mapping.legacy_id}:#{source_checksum}:0"
        errors.add(:first_batch, "must identify the exact retained account archive and owner")
      end
    end

    def immutable_receipt
      errors.add(:base, "Retained account bindings cannot change") if has_changes_to_save?
    end
end
