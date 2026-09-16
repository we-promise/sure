class EntrySource < ApplicationRecord
  belongs_to :source_record
  belongs_to :entry, optional: true
  belongs_to :account, optional: true
  belongs_to :account_identity, class_name: "Account::IngestionIdentity", foreign_key: :account_id
  belongs_to :family
  belongs_to :bootstrap_batch, class_name: "IngestionBatch", optional: true
  belongs_to :bootstrap_external_account, class_name: "ExternalAccount", optional: true

  validates :role, inclusion: { in: %w[posting evidence] }
  validates :match_method, presence: true
  before_validation :remember_entry_identity, on: :create
  before_validation :remember_bootstrap_type, on: :create
  validates :entry_identity, presence: true
  validates :source_record_id, uniqueness: { conditions: -> { where(active: true) } }, if: :active?
  validates :entry, presence: true, if: :active?
  validate :same_account_and_family
  validate :valid_bootstrap_evidence
  attr_readonly :source_record_id, :entry_id, :entry_identity, :account_id, :family_id, :role, :match_method
  attr_readonly :bootstrap_batch_id, :bootstrap_external_account_id, :bootstrap_identity_role, :bootstrap_entryable_type, :bootstrap_identity_state

  private
    def remember_entry_identity
      self.entry_identity ||= entry_id
    end

    def remember_bootstrap_type
      return unless bootstrap_batch_id && entry
      self.bootstrap_entryable_type ||= entry.entryable_type
      self.bootstrap_identity_state ||= Ingestion::FinancialIdentityState.from_snapshot("entry" => entry.attributes, "entryable" => entry.entryable.attributes)
    end

    def same_account_and_family
      unless source_record && source_record.account_id == account_id &&
          (!entry || (entry.account_id == account_id && entry.id == entry_identity)) && source_record.family_id == family_id &&
          valid_account_identity?
        errors.add(:base, "Evidence and entry must belong to the same account and family")
      end
    end

    def valid_account_identity?
      identity = account_identity
      return false unless identity && identity.family_id == family_id
      if identity.retired?
        !new_record? && account.nil? && !active? && entry_id.nil?
      else
        identity.live_account_id == account_id && account&.family_id == family_id
      end
    end

    def valid_bootstrap_evidence
      present = [ bootstrap_batch_id, bootstrap_external_account_id, bootstrap_identity_role, bootstrap_entryable_type, bootstrap_identity_state ].compact
      if present.empty?
        errors.add(:bootstrap_batch, "is required for a migrated financial identity") if source_record&.ingestion_batch&.origin_kind == "migration"
        return
      end
      unless present.size == 5 && %w[current retired_alias].include?(bootstrap_identity_role) &&
          %w[Transaction Trade].include?(bootstrap_entryable_type) && bootstrap_identity_state.is_a?(Hash)
        errors.add(:bootstrap_batch, "must describe one complete identity")
        return
      end
      Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: self, source_record: source_record, require_applied: !new_record?)
    rescue Ingestion::LegacyIdentityEvidence::InvalidEvidence
      errors.add(:bootstrap_batch, "must contain this exact source and financial identity")
    end
end
