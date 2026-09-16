class ProviderSyncCheckpoint < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  encrypts :cursor
  encrypted_document :state

  belongs_to :family
  belongs_to :provider_connection
  belongs_to :provider_authorization, optional: true
  belongs_to :external_account, optional: true
  belongs_to :ingestion_batch, optional: true
  belongs_to :provider_sync_generation, optional: true

  before_validation :inherit_family
  validates :stream, :scope_key, presence: true
  validates :scope_key, uniqueness: { scope: [ :provider_connection_id, :stream ] }
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }
  validate :same_scope

  private
    def inherit_family
      self.family_id ||= provider_connection&.family_id
    end

    def same_scope
      validate_family_of(provider_connection, :provider_connection)
      validate_connection_of(provider_authorization, :provider_authorization)
      validate_connection_of(external_account, :external_account)
      validate_connection_of(ingestion_batch, :ingestion_batch)
      validate_connection_of(provider_sync_generation, :provider_sync_generation)
      validate_documents(:state)
      if provider_sync_generation
        unless provider_sync_generation.applied? && provider_sync_generation.stream == stream && provider_sync_generation.scope_key == scope_key &&
            ingestion_batch_id.nil? && external_account_id.nil? && provider_authorization_id.nil? && cursor == provider_sync_generation.terminal_cursor && state["progress"].nil?
          errors.add(:provider_sync_generation, "must be a fully applied generation for this connection cursor")
        end
      end
      if state.is_a?(Hash) && state["progress"]
        progress = state["progress"]
        unless progress.is_a?(Hash) && progress["cursor"].is_a?(String) && progress["cursor"].present?
          errors.add(:state, "has invalid fetch progress")
          return
        end
        progress_batch = provider_connection.ingestion_batches.find_by(id: progress["ingestion_batch_id"])
        unless progress_batch&.applied? && progress_batch.stream == stream && progress_batch.scope_key == scope_key &&
            progress_batch.external_account_id == external_account_id && progress_batch.provider_authorization_id == provider_authorization_id
          errors.add(:state, "fetch progress must reference an applied batch for this scope")
        end
      end
      return unless ingestion_batch

      unless ingestion_batch.applied? && ingestion_batch.stream == stream && ingestion_batch.scope_key == scope_key &&
          ingestion_batch.external_account_id == external_account_id && ingestion_batch.provider_authorization_id == provider_authorization_id
        errors.add(:ingestion_batch, "must be an applied batch for this exact stream and scope")
      end
    end
end
