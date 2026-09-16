# Read-only admission for account calculations. A retained identity is evidence
# of the original owner, never a substitute for the live financial account.
class Account::SyncAdmission
  SUPPORTED_STATES = %w[active draft disabled].freeze
  class Unavailable < Provider::AccountData::StaleWriter; end

  def self.current(account_id:, family_id: nil, lock: false)
    if lock && Account.connection.open_transactions.zero?
      raise ArgumentError, "Locked account admission requires a transaction"
    end
    ApplicationRecord.uncached do
      accounts = Account.where(id: account_id)
      accounts = accounts.lock("FOR UPDATE NOWAIT") if lock
      account = accounts.first
      next nil unless account && SUPPORTED_STATES.include?(account.status) && (family_id.nil? || account.family_id == family_id)

      identities = Account::IngestionIdentity.where(id: account.id)
      identities = identities.lock("FOR SHARE NOWAIT") if lock
      identity = identities.first
      if identity && (identity.retired? || identity.family_id != account.family_id || identity.live_account_id != account.id)
        next nil
      end
      account
    end
  end

  def self.fetch!(account_id:, family_id: nil, lock: false)
    current(account_id: account_id, family_id: family_id, lock: lock) ||
      raise(Unavailable, "Financial account is unavailable for synchronization")
  end
end
