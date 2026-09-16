# The source of one calculation. New jobs copy a selected input; no job reads a
# mutable latest-export pointer after its inputs have been sealed.
class Account::SyncInput < ApplicationRecord
  self.table_name = "account_sync_inputs"
  include ProviderDataEncryption
  encrypted_document :payload

  belongs_to :account, optional: true
  belongs_to :account_identity, class_name: "Account::IngestionIdentity", foreign_key: :account_id, optional: true
  belongs_to :family
  belongs_to :sync
  belongs_to :provider_sync, class_name: "Sync"
  belongs_to :source_batch, class_name: "IngestionBatch"
  validates :resource, inclusion: { in: [ "historical_balances" ] }
  validates :kind, inclusion: { in: [ "ibkr_equity" ] }
  validate :consistent_evidence
  before_create :capture_account_identity

  before_update -> { raise ActiveRecord::ReadOnlyRecord, "Account sync evidence is immutable" }

  def handoff
    Provider::AccountData::Ibkr::EquityHandoff.load(payload)
  end

  def resolve!
    current = Account::SyncAdmission.fetch!(account_id: account_id, family_id: family_id)
    unless payload_digest == Ingestion::HistoricalBalances.fingerprint(payload)
      raise Provider::AccountData::InvalidResponse, "Account sync input digest changed"
    end
    handoff.resolve(account: current, provider_sync: provider_sync)
  end

  def self.digest(inputs)
    Ingestion::HistoricalBalances.fingerprint(inputs.sort_by(&:resource).map do |input|
      { "resource" => input.resource, "kind" => input.kind, "payload" => input.payload }
    end)
  end

  private
    def capture_account_identity
      current = Account::SyncAdmission.fetch!(account_id: account_id, family_id: family_id, lock: true)
      self.account_identity = Account::IngestionIdentity.capture!(account: current)
      self.account = current
    end

    def consistent_evidence
      owner_valid = if new_record?
        Account::SyncAdmission.current(account_id: account_id, family_id: family_id).present? && sync&.in_progress? && sync.account_inputs_sealed_at.nil?
      else
        account_identity&.family_id == family_id
      end
      unless owner_valid && sync&.syncable_type == "Account" && sync.syncable_id == account_id && sync.account_family_id == family_id &&
          source_batch && source_batch.sync_id == provider_sync_id && source_batch.family_id == family_id &&
          payload["account_id"] == account_id && payload["family_id"] == family_id && payload["provider_sync_id"] == provider_sync_id &&
          payload["source_batch_id"] == source_batch_id && payload_digest == Ingestion::HistoricalBalances.fingerprint(payload)
        errors.add(:base, "must preserve the original account, family, execution and source evidence")
      end
      handoff
    rescue ArgumentError, KeyError, TypeError
      errors.add(:payload, "must be a typed historical handoff")
    end
end
