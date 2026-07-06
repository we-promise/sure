class OpenBankingIoAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # open-banking.io reports the ISO 20022 cash-account type. We map the two we
  # support to Sure accountable types (CACC = current/checking, CARD = card).
  OPEN_BANKING_IO_ACCOUNT_TYPE_MAP = {
    "CACC" => { accountable_type: "Depository", subtype: "checking" },
    "CARD" => { accountable_type: "CreditCard", subtype: "credit_card" }
  }.freeze

  # ISO 20022 booked balance code used as the account's current balance.
  BOOKED_BALANCE_TYPE = "ITBD".freeze
  # ISO 20022 available balance code.
  AVAILABLE_BALANCE_TYPE = "ITAV".freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :open_banking_io_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :open_banking_io_item_id, allow_nil: true }

  def current_account
    account
  end

  def suggested_account_type
    OPEN_BANKING_IO_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.fetch(:accountable_type)
  end

  def suggested_subtype
    OPEN_BANKING_IO_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.[](:subtype)
  end

  def upsert_open_banking_io_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    balances = snapshot[:balances].is_a?(Array) ? snapshot[:balances] : []

    booked = find_balance(balances, BOOKED_BALANCE_TYPE) || balances.first
    available = find_balance(balances, AVAILABLE_BALANCE_TYPE)

    display_name = snapshot[:display_name].presence ||
                   snapshot[:account_name].presence ||
                   snapshot[:aspsp_name].presence ||
                   I18n.t("open_banking_io_account.fallback")

    assign_attributes(
      current_balance: parse_balance_amount(booked) || 0,
      available_balance: parse_balance_amount(available),
      currency: parse_currency(snapshot[:currency]) || parse_currency(booked&.dig(:currency)) || "EUR",
      name: display_name,
      account_id: snapshot[:id].presence,
      formatted_account: snapshot[:iban].presence || snapshot[:bban].presence,
      account_status: snapshot[:needs_reconnect] ? "requires_update" : "good",
      account_type: snapshot[:account_type],
      provider: "open_banking_io",
      institution_metadata: {
        id: snapshot[:aspsp_name],
        name: snapshot[:aspsp_name],
        country: snapshot[:aspsp_country],
        bic: snapshot[:bic],
        account_number: snapshot[:iban].presence || snapshot[:bban].presence,
        holder: snapshot[:owner_name]
      }.compact,
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_open_banking_io_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def find_balance(balances, type)
      balances.find { |b| b.is_a?(Hash) && b.with_indifferent_access[:type].to_s.upcase == type }&.with_indifferent_access
    end

    def parse_balance_amount(balance)
      return nil unless balance.is_a?(Hash)

      value = balance.with_indifferent_access[:amount]
      return nil if value.nil? || value == ""

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for open-banking.io account #{id}, defaulting to EUR")
    end
end
