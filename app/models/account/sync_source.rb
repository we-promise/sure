# Explicitly selected when a provider hands off its completed account streams.
# Ad hoc calculations copy this input into their own sealed input set.
class Account::SyncSource < ApplicationRecord
  self.table_name = "account_sync_sources"
  belongs_to :account, optional: true
  belongs_to :account_identity, class_name: "Account::IngestionIdentity", foreign_key: :account_id, optional: true
  belongs_to :family
  belongs_to :account_sync_input, class_name: "Account::SyncInput"
  validates :resource, uniqueness: { scope: :account_id }
  validate :consistent_evidence
  before_save :admit_live_owner
  before_destroy :preserve_retired_selection
  attr_readonly :account_id, :family_id, :resource

  private
    def consistent_evidence
      input = account_sync_input
      unless input && input.account_id == account_id && input.family_id == family_id && input.resource == resource &&
          account_identity&.family_id == family_id
        errors.add(:account_sync_input, "must preserve the selected account, family and resource")
      end
      if (new_record? || has_changes_to_save?) && !Account::SyncAdmission.current(account_id: account_id, family_id: family_id)
        errors.add(:account, "must be available before changing the selected input")
      end
    end

    def admit_live_owner
      self.account = Account::SyncAdmission.fetch!(account_id: account_id, family_id: family_id, lock: true)
    end

    def preserve_retired_selection
      if Account::IngestionIdentity.where(id: account_id, family_id: family_id).where.not(retired_at: nil).exists?
        raise ActiveRecord::ReadOnlyRecord, "Retired account input selection must be retained"
      end
    end
end
