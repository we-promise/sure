class IngestionBatch < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  encrypted_document :payload, :ruleset_snapshot

  CAPTURED_ATTRIBUTES = %w[
    family_id origin_kind provider_connection_id provider_authorization_id
    external_account_id sync_id provider_sync_type import_id account_statement_id
    stream scope_key sequence idempotency_key schema_version mode complete coverage
    payload ruleset_snapshot source_policy_version writer_epoch
    provider_sync_generation_id generation_role generation_resource source_binding
  ].freeze

  belongs_to :family
  belongs_to :provider_connection, optional: true
  belongs_to :provider_authorization, optional: true
  belongs_to :external_account, optional: true
  belongs_to :sync, optional: true
  belongs_to :provider_sync_generation, optional: true
  belongs_to :import, optional: true
  belongs_to :account_statement, optional: true
  has_many :provider_sync_checkpoints, dependent: :restrict_with_error

  enum :status, { captured: "captured", applying: "applying", applied: "applied", failed: "failed", review_required: "review_required", approved: "approved" }, default: :captured, validate: true

  before_validation :inherit_family
  validates :origin_kind, inclusion: { in: %w[provider file migration] }
  validates :mode, inclusion: { in: %w[delta snapshot unknown] }
  validates :complete, inclusion: { in: [ true, false ] }
  validates :stream, :scope_key, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: { scope: :family_id }
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }
  validates :writer_epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :origin_and_ownership
  validate :historical_command_binding
  validate :immutable_capture

  private
    def inherit_family
      self.family_id ||= provider_connection&.family_id || import&.family_id
      self.generation_resource ||= provider_sync_generation&.stream
    end

    def origin_and_ownership
      validate_family_of(provider_connection, :provider_connection)
      validate_connection_of(provider_authorization, :provider_authorization)
      validate_connection_of(external_account, :external_account)
      validate_connection_of(provider_sync_generation, :provider_sync_generation)
      validate_family_of(import, :import)
      validate_family_of(account_statement, :account_statement)
      validate_documents(:payload, :ruleset_snapshot, :coverage, :source_binding)
      if source_binding.present? && !(source_binding.is_a?(Hash) && origin_kind == "provider" && external_account_id &&
          source_binding["external_account_id"] == external_account_id && source_binding["resource"] == stream &&
          source_binding["source_policy_version"] == source_policy_version)
        errors.add(:source_binding, "must describe this account resource and captured policy")
      end
      errors.add(:complete, "requires known coverage semantics") if complete? && mode == "unknown"
      if provider_sync_generation
        unless generation_resource == provider_sync_generation.stream && origin_kind == "provider" && provider_authorization_id.nil? && sync_id == provider_sync_generation.sync_id && writer_epoch == provider_sync_generation.writer_epoch &&
            ((generation_role == "page" && stream == { "transactions" => "transaction_groups", "activities" => "activity_groups" }[provider_sync_generation.stream] && scope_key == "connection" && external_account_id.nil?) ||
             (generation_role == "account" && stream == provider_sync_generation.stream && external_account_id.present? && scope_key == "account:#{external_account_id}"))
          errors.add(:provider_sync_generation, "must match the captured generation and role")
        end
        errors.add(:provider_sync_generation, "has already sealed its evidence") if new_record? && !provider_sync_generation.fetching?
      elsif generation_role || generation_resource
        errors.add(:generation_role, "requires a generation")
      end

      case origin_kind
      when "provider"
        errors.add(:provider_connection, "is required") unless provider_connection
        errors.add(:sync, "must sync this provider connection") unless sync&.syncable_type == "ProviderConnection" && sync.syncable_id == provider_connection_id
        errors.add(:writer_epoch, "is required") if writer_epoch.nil?
        errors.add(:import, "cannot belong to a provider batch") if import_id || account_statement_id
      when "migration"
        errors.add(:provider_connection, "is required") unless provider_connection
        errors.add(:origin_kind, "cannot manufacture sync or file context") if sync_id || import_id || account_statement_id
      when "file"
        errors.add(:import, "is required") unless import
        if provider_connection_id || provider_authorization_id || external_account_id || sync_id
          errors.add(:origin_kind, "cannot have provider context")
        end
        if import && import.account_statement_id != account_statement_id
          errors.add(:account_statement, "must be the import's statement")
        end
      end
    end

    def historical_command_binding
      return unless origin_kind == "provider" && Ingestion::HistoricalBalances::SourceBinding::STREAMS.include?(stream)
      # Empty rollout-era bindings are explicitly unindexed. Completing one is
      # reserved for the original-command verifier, which uses update_columns.
      return if source_binding == {}

      command = Ingestion::HistoricalBalances::Command.load(payload)
      unless source_binding == Ingestion::HistoricalBalances::SourceBinding.capture(command: command)
        errors.add(:source_binding, "must match the original historical command")
      end
    rescue Ingestion::HistoricalBalances::SourceBinding::Conflict, ArgumentError, KeyError, TypeError
      errors.add(:source_binding, "must match a valid historical command")
    end

    def immutable_capture
      return if new_record?

      CAPTURED_ATTRIBUTES.each do |attribute|
        errors.add(attribute, "is captured evidence and cannot change") if will_save_change_to_attribute?(attribute)
      end
    end
end
