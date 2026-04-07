# Represents a CoinStats-backed synced account.
# This may be a wallet-scoped asset row or a consolidated exchange portfolio.
class CoinstatsAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include CoinstatsAccount::ValueHelpers
  include CoinstatsAccount::SourceClassification
  include CoinstatsAccount::BalanceInference

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :coinstats_item

  # Association through account_providers (standard pattern for all providers)
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: [ :coinstats_item_id, :wallet_address ], allow_nil: true }

  # Alias for compatibility with provider adapter pattern
  alias_method :current_account, :account

  # Updates account with latest balance data from CoinStats API.
  # @param account_snapshot [Hash] Normalized balance data from API
  def upsert_coinstats_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    attrs = {
      current_balance: snapshot[:balance] || snapshot[:current_balance] || inferred_current_balance(snapshot),
      currency: inferred_currency(snapshot) || parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_status: snapshot[:status],
      provider: snapshot[:provider],
      institution_metadata: {
        logo: snapshot[:institution_logo]
      }.compact,
      raw_payload: account_snapshot
    }

    attrs[:account_id] = snapshot[:id].to_s if snapshot[:id].present? && account_id.blank?

    update!(attrs)
  end

  # Stores transaction data from CoinStats API for later processing.
  # @param transactions_snapshot [Hash, Array] Raw transactions response or array
  def upsert_coinstats_transactions_snapshot!(transactions_snapshot)
    transactions_array = if transactions_snapshot.is_a?(Hash)
      snapshot = transactions_snapshot.with_indifferent_access
      snapshot[:result] || []
    elsif transactions_snapshot.is_a?(Array)
      transactions_snapshot
    else
      []
    end

    assign_attributes(raw_transactions_payload: transactions_array)
    save!
  end
end
