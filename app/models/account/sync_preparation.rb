class Account::SyncPreparation < ApplicationRecord
  self.table_name = "account_sync_preparations"
  include ProviderDataEncryption
  encrypted_document :payload
  belongs_to :sync
  validates :sync_id, uniqueness: true
  validate :consistent_evidence
  before_create :capture_account_identity

  before_update -> { raise ActiveRecord::ReadOnlyRecord, "Account preparation is immutable" }

  def trade_flows
    unless sync&.syncable_type == "Account" && sync.account_inputs_sealed_at && input_digest == sync.account_inputs_digest
      raise Provider::AccountData::InvalidResponse, "Account preparation has different sealed inputs"
    end
    snapshot = Ingestion::HistoricalBalances::TradeFlowSnapshot.load(payload)
    unless snapshot.data.fetch("account_id") == sync.syncable_id
      raise Provider::AccountData::InvalidResponse, "Account preparation belongs to a different account"
    end
    snapshot
  end

  private
    def capture_account_identity
      current = Account::SyncAdmission.fetch!(account_id: sync.syncable_id, family_id: sync.account_family_id, lock: true)
      Account::IngestionIdentity.capture!(account: current)
    end

    def consistent_evidence
      trade_flows
      identity = Account::IngestionIdentity.find_by(id: sync.syncable_id, family_id: sync.account_family_id)
      unless sync.account_family_id && (new_record? || identity)
        errors.add(:base, "must retain the original financial account identity")
      end
      if new_record? && (!sync.syncing? || !Account::SyncAdmission.current(account_id: sync.syncable_id, family_id: sync.account_family_id))
        errors.add(:base, "requires a live account and running sealed execution")
      end
    rescue ArgumentError, KeyError, TypeError, Provider::AccountData::InvalidResponse
      errors.add(:payload, "must preserve the original account trade preparation")
    end
end
