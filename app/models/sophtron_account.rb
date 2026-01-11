# Represents a single bank account from Sophtron.
#
# A SophtronAccount stores account-level data fetched from the Sophtron API,
# including balances, account type, and raw transaction data. It can be linked
# to a Maybe Account through the account_provider association.
#
# @attr [String] name Account name from Sophtron
# @attr [String] account_id Sophtron's unique identifier for this account
# @attr [String] customer_id Sophtron customer ID this account belongs to
# @attr [String] member_id Sophtron member ID
# @attr [String] currency Three-letter currency code (e.g., 'USD')
# @attr [Decimal] balance Current account balance
# @attr [Decimal] available_balance Available balance (for credit accounts)
# @attr [String] account_type Type of account (e.g., 'checking', 'savings')
# @attr [String] account_sub_type Detailed account subtype
# @attr [JSONB] raw_payload Raw account data from Sophtron API
# @attr [JSONB] raw_transactions_payload Raw transaction data from Sophtron API
# @attr [DateTime] last_updated When Sophtron last updated this account
class SophtronAccount < ApplicationRecord
  include CurrencyNormalizable

  belongs_to :sophtron_item

  # Association to link this Sophtron account to a Maybe Account
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Returns the linked Maybe Account for this Sophtron account.
  #
  # @return [Account, nil] The linked Maybe Account, or nil if not linked
  def current_account
    account
  end

  # Updates this SophtronAccount with fresh data from the Sophtron API.
  #
  # Maps Sophtron field names to our database schema and saves the changes.
  # Stores the complete raw payload for reference.
  #
  # @param account_snapshot [Hash] Raw account data from Sophtron API
  # @return [Boolean] true if save was successful
  # @raise [ActiveRecord::RecordInvalid] if validation fails
  def upsert_sophtron_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map Sophtron field names to our field names
    assign_attributes(
      name: snapshot[:account_name],
      account_id: snapshot[:account_id],
      currency: parse_currency(snapshot[:balance_currency])|| "USD",
      balance: parse_balance(snapshot[:balance]),
      available_balance: parse_balance(snapshot[:"available-balance"]),
      account_type: snapshot["account_type"] || "unknown",
      account_sub_type: snapshot["sub_type"] || "unknown",
      last_updated: parse_balance_date(snapshot[:"last_updated"]),
      raw_payload: account_snapshot,
      customer_id: snapshot["customer_id"],
      member_id: snapshot["member_id"]
    )

    save!
  end

  # Stores raw transaction data from the Sophtron API.
  #
  # This method saves the raw transaction payload which will later be
  # processed by SophtronAccount::Transactions::Processor to create
  # actual Transaction records.
  #
  # @param transactions_snapshot [Array<Hash>] Array of raw transaction data
  # @return [Boolean] true if save was successful
  # @raise [ActiveRecord::RecordInvalid] if validation fails
  def upsert_sophtron_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Sophtron account #{id}, defaulting to USD")
    end


    def parse_balance(balance_value)
      return nil if balance_value.nil?

      case balance_value
      when String
        BigDecimal(balance_value)
      when Numeric
        BigDecimal(balance_value.to_s)
      else
        nil
      end
    rescue ArgumentError
      nil
    end

    def parse_balance_date(balance_date_value)
      return nil if balance_date_value.nil?

      case balance_date_value
      when String
        Time.parse(balance_date_value)
      when Numeric
        Time.at(balance_date_value)
      when Time, DateTime
        balance_date_value
      else
        nil
      end
    rescue ArgumentError, TypeError
      Rails.logger.warn("Invalid balance date for Sophtron account: #{balance_date_value}")
      nil
    end
    def has_balance
      return if balance.present? || available_balance.present?
      errors.add(:base, "Sophtron account must have either current or available balance")
    end
end
