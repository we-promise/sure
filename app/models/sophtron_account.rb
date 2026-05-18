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

  scope :requires_manual_sync, -> { where(manual_sync: true) }
  scope :automatic_sync, -> { where(manual_sync: false) }

  validates :name, :currency, presence: true
  validate :has_balance
  # Returns the linked Maybe Account for this Sophtron account.
  #
  # @return [Account, nil] The linked Maybe Account, or nil if not linked
  def current_account
    account
  end

  def institution_name
    institution_metadata.to_h["name"].presence || sophtron_item&.institution_name
  end

  def institution_user_institution_id
    institution_metadata.to_h["user_institution_id"].presence || sophtron_item&.user_institution_id
  end

  def institution_key
    institution_user_institution_id.presence || institution_name
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
    account_id = first_present(snapshot, :account_id, :id, :AccountID)
    account_name = first_present(snapshot, :account_name, :name, :AccountName)
    account_number = first_present(snapshot, :account_number, :AccountNumber)
    currency = first_present(snapshot, :balance_currency, :currency, :BalanceCurrency, :Currency)
    balance = first_present(snapshot, :balance, :account_balance, :AccountBalance, :Balance)
    available_balance = first_present(snapshot, :"available-balance", :available_balance, :AvailableBalance)
    account_type = first_present(snapshot, :account_type, :type, :AccountType)
    account_sub_type = first_present(snapshot, :sub_type, :account_sub_type, :AccountSubType, :SubType)
    last_updated = first_present(snapshot, :last_updated, :LastUpdated)
    institution_name = first_present(snapshot, :institution_name, :InstitutionName).presence || sophtron_item&.institution_name
    user_institution_id = first_present(snapshot, :user_institution_id, :UserInstitutionID).presence || sophtron_item&.user_institution_id

    # Map Sophtron field names to our field names
    assign_attributes(
      name: account_name,
      account_id: account_id,
      currency: parse_currency(currency) || "USD",
      balance: parse_balance(balance),
      available_balance: parse_balance(available_balance),
      account_type: account_type.presence || "unknown",
      account_sub_type: account_sub_type.presence || "unknown",
      last_updated: parse_balance_date(last_updated),
      account_status: first_present(snapshot, :account_status, :status, :AccountStatus, :Status),
      account_number_mask: snapshot[:account_number_mask].presence || mask_account_number(account_number),
      institution_metadata: {
        name: institution_name,
        user_institution_id: user_institution_id
      }.compact,
      raw_payload: account_snapshot,
      customer_id: first_present(snapshot, :customer_id, :CustomerID) || customer_id,
      member_id: first_present(snapshot, :member_id, :MemberID) || member_id
    )
    self.manual_sync = true if new_record? && sophtron_item&.manual_sync?

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
        t = balance_date_value
        t = (t / 1000.0) if t > 1_000_000_000_000 # likely ms epoch
        Time.at(t)
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
      errors.add(:base, :no_balance)
    end

    def first_present(hash, *keys)
      keys.each do |key|
        value = hash[key]
        return value if value.present?
      end

      nil
    end

    def mask_account_number(account_number)
      return nil if account_number.blank?

      last_four = account_number.to_s.gsub(/\s+/, "").last(4)
      last_four.present? ? "****#{last_four}" : nil
    end
end
