# frozen_string_literal: true

class WiseAccount < ApplicationRecord
  include Encryptable

  # Kept from the stored snapshot when a new one lacks them: the recipient
  # ids that decide transfer direction (a failed lookup must not flip it)
  # and Sure's own markers on the balance.
  PRESERVED_KEYS = %w[
    recipient_id borderless_account_id recipientId closed_at absent_count statements_coverage name_history
  ].freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :wise_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :balance_id, :currency, presence: true
  validates :balance_id, uniqueness: { scope: :wise_item_id }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }

  def current_account
    account
  end

  def jar?
    raw_payload&.dig("type") == "SAVINGS"
  end

  # Wise no longer lists the balance (raw_payload "closed_at", one of
  # PRESERVED_KEYS).
  def closed?
    raw_payload.is_a?(Hash) && raw_payload["closed_at"].present?
  end

  def account_subtype
    jar? ? "savings" : Depository::DEFAULT_SUBTYPE
  end

  def upsert_wise_snapshot!(balance_data, borderless_account_id: nil, recipient_id: nil)
    data = balance_data.with_indifferent_access
    payload = balance_data.is_a?(Hash) ? balance_data.dup : balance_data
    payload = payload.merge("borderless_account_id" => borderless_account_id) if borderless_account_id
    payload = payload.merge("recipient_id" => recipient_id) if recipient_id
    previous = raw_payload.is_a?(Hash) ? raw_payload : {}
    PRESERVED_KEYS.each do |key|
      payload = payload.merge(key => previous[key]) if previous.key?(key) && !payload.key?(key)
    end

    currency_code = data.dig(:amount, :currency).presence || data[:currency].presence || currency
    savings = data[:type] == "SAVINGS"
    balance_value = savings ? data.dig(:totalWorth, :value).to_d : data.dig(:amount, :value).to_d
    api_name = data[:name].presence
    default_name = savings ? "Wise JAR #{currency_code}" : "Wise #{currency_code}"

    update!(
      current_balance: balance_value,
      reserved_balance: data.dig(:reservedAmount, :value).to_d,
      currency: currency_code,
      name: name.presence || api_name || default_name,
      raw_payload: payload
    )
  end

  def upsert_wise_transactions_snapshot!(transactions)
    update!(raw_transactions_payload: transactions)
  end
end
