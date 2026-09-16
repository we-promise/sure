# Original financial-account identity. Evidence keeps this UUID after its live
# ledger is retired; a missing live Account must never mean an unbound observation.
class Account::IngestionIdentity < ApplicationRecord
  self.table_name = "account_ingestion_identities"

  class Conflict < Provider::AccountData::InvalidResponse; end
  class Busy < Provider::AccountData::IncompletePage; end

  belongs_to :family
  belongs_to :live_account, class_name: "Account", optional: true
  has_many :source_records, foreign_key: :account_id, dependent: :restrict_with_error
  has_many :source_policies, class_name: "Account::SourcePolicy", foreign_key: :account_id, dependent: :restrict_with_error
  has_many :sync_inputs, class_name: "Account::SyncInput", foreign_key: :account_id, dependent: :restrict_with_error

  attr_readonly :id, :family_id, :created_at
  validate :consistent_live_identity
  validate :retirement_requires_command

  def retired? = retired_at.present?

  # Publication already locks the Account. Standalone callers take that same
  # lock before creating or inspecting an identity, and fail promptly on contention.
  # No code path may recreate an account identity from a historical UUID alone.
  def self.capture!(account:)
    unless account.is_a?(Account) && account.persisted? && !account.destroyed?
      raise Conflict, "Expected a live financial account"
    end
    uncached do
      transaction(requires_new: true) do
        current = Account.where(id: account.id, family_id: account.family_id).lock("FOR UPDATE NOWAIT").first!
        raise Conflict, "Financial account is pending deletion" if current.pending_deletion?
        identity = where(id: current.id).lock("FOR UPDATE NOWAIT").first
        if identity
          unless identity.family_id == current.family_id && identity.live_account_id == current.id && !identity.retired?
            raise Conflict, "Financial account identity is already retired or belongs to another family"
          end
          identity
        else
          create!(id: current.id, family_id: current.family_id, live_account: current)
        end
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Busy, "Financial account identity is being changed; retry publication", cause: nil
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Financial account identity has no live owner", cause: nil
  end

  private
    def consistent_live_identity
      valid = if retired?
        live_account_id.nil?
      else
        live_account_id == id && live_account&.family_id == family_id
      end
      errors.add(:base, "must preserve the original account and family identity") unless valid
    end

    def retirement_requires_command
      if (new_record? && retired?) || (!new_record? && (will_save_change_to_retired_at? || will_save_change_to_live_account_id?))
        errors.add(:base, "retirement requires the admitted account lifecycle command")
      end
    end
end
