class AkahuAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  AKAHU_ACCOUNT_TYPE_MAP = {
    "CHECKING" => { accountable_type: "Depository", subtype: "checking" },
    "SAVINGS" => { accountable_type: "Depository", subtype: "savings" },
    "TERMDEPOSIT" => { accountable_type: "Depository", subtype: "cd" },
    "CREDITCARD" => { accountable_type: "CreditCard", subtype: "credit_card" },
    "LOAN" => { accountable_type: "Loan" },
    "KIWISAVER" => { accountable_type: "Investment", subtype: "retirement" },
    "INVESTMENT" => { accountable_type: "Investment" }
  }.freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :akahu_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :akahu_item_id, allow_nil: true }

  def current_account
    account
  end

  def suggested_account_type
    AKAHU_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.fetch(:accountable_type)
  end

  def suggested_subtype
    AKAHU_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.[](:subtype)
  end

  def upsert_akahu_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    balance = snapshot[:balance].is_a?(Hash) ? snapshot[:balance].with_indifferent_access : {}
    connection = snapshot[:connection].is_a?(Hash) ? snapshot[:connection].with_indifferent_access : {}
    meta = snapshot[:meta].is_a?(Hash) ? snapshot[:meta].with_indifferent_access : {}
    payment_details = meta[:payment_details].is_a?(Hash) ? meta[:payment_details].with_indifferent_access : {}

    display_name = if connection[:name].present? && snapshot[:name].present?
      "#{connection[:name]} - #{snapshot[:name]}"
    else
      snapshot[:name].presence || connection[:name].presence || I18n.t("akahu_account.fallback")
    end

    assign_attributes(
      current_balance: balance[:current] || 0,
      available_balance: balance[:available],
      balance_limit: balance[:limit],
      currency: parse_currency(balance[:currency]) || "NZD",
      name: display_name,
      account_id: snapshot[:_id].presence || snapshot[:id].presence,
      formatted_account: snapshot[:formatted_account].presence || payment_details[:account_number],
      account_status: snapshot[:status],
      account_type: snapshot[:type],
      provider: "akahu",
      institution_metadata: {
        id: connection[:_id].presence || connection[:id],
        name: connection[:name],
        logo: connection[:logo],
        account_number: snapshot[:formatted_account].presence || payment_details[:account_number],
        holder: meta[:holder].presence || payment_details[:account_holder]
      }.compact,
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_akahu_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Akahu account #{id}, defaulting to NZD")
    end
end
