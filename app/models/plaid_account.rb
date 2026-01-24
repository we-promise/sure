class PlaidAccount < ApplicationRecord
  include Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    # Support reading data encrypted under the old column name after rename
    encrypts :raw_holdings_payload, previous: { attribute: :raw_investments_payload }
    encrypts :raw_liabilities_payload
  end

  belongs_to :plaid_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :plaid_type, :currency, presence: true
  validate :has_balance

  def current_account
    linked_account
  end

  # Ensure there is an AccountProvider link for this Plaid account.
  # Safe and idempotent; returns the AccountProvider or nil if no account is provided.
  def ensure_account_provider!(account = nil)
    # If already linked and no new account specified, return existing
    if account_provider.present?
      if account && account_provider.account_id != account.id
        account_provider.update!(account: account)
      end
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "PlaidAccount", provider_id: id)
      .tap do |p|
        p.account = acct
        p.save!
      end

    # Reload the association so future accesses don't return stale/nil value
    reload_account_provider

    provider
  rescue => e
    Rails.logger.warn("PlaidAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}")
    nil
  end

  def upsert_plaid_snapshot!(account_snapshot)
    assign_attributes(
      current_balance: account_snapshot.balances.current,
      available_balance: account_snapshot.balances.available,
      currency: account_snapshot.balances.iso_currency_code,
      plaid_type: account_snapshot.type,
      plaid_subtype: account_snapshot.subtype,
      name: account_snapshot.name,
      mask: account_snapshot.mask,
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_plaid_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  def upsert_plaid_holdings_snapshot!(holdings_snapshot)
    assign_attributes(
      raw_holdings_payload: holdings_snapshot
    )

    save!
  end

  def upsert_plaid_liabilities_snapshot!(liabilities_snapshot)
    assign_attributes(
      raw_liabilities_payload: liabilities_snapshot
    )

    save!
  end

  private
    # Plaid guarantees at least one of these.  This validation is a sanity check for that guarantee.
    def has_balance
      return if current_balance.present? || available_balance.present?
      errors.add(:base, "Plaid account must have either current or available balance")
    end
end
