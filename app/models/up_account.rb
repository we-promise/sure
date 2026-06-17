class UpAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Maps Up `accountType` values to Sure accountable types/subtypes.
  UP_ACCOUNT_TYPE_MAP = {
    "TRANSACTIONAL" => { accountable_type: "Depository", subtype: "checking" },
    "SAVER" => { accountable_type: "Depository", subtype: "savings" },
    "HOME_LOAN" => { accountable_type: "Loan" }
  }.freeze

  INSTITUTION_NAME = "Up".freeze
  INSTITUTION_DOMAIN = "up.com.au".freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :up_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :up_item_id, allow_nil: true }

  def current_account
    account
  end

  def suggested_account_type
    UP_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.fetch(:accountable_type)
  end

  def suggested_subtype
    UP_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.[](:subtype)
  end

  def upsert_up_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    balance = snapshot[:balance].is_a?(Hash) ? snapshot[:balance].with_indifferent_access : {}

    assign_attributes(
      current_balance: parse_balance(balance[:value]),
      currency: parse_currency(balance[:currencyCode]) || "AUD",
      name: snapshot[:displayName].presence || I18n.t("up_account.fallback"),
      account_id: snapshot[:id],
      account_status: snapshot[:accountType],
      account_type: snapshot[:accountType],
      ownership_type: snapshot[:ownershipType],
      provider: "up",
      institution_metadata: {
        name: INSTITUTION_NAME,
        domain: INSTITUTION_DOMAIN
      }.compact,
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_up_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def parse_balance(value)
      return 0 if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      0
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Up account #{id}, defaulting to AUD")
    end
end
