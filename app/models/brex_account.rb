# frozen_string_literal: true

class BrexAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  CARD_PRIMARY_ACCOUNT_ID = "card_primary"

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :brex_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :brex_item_id }
  validates :account_kind, inclusion: { in: %w[cash card] }

  def self.card_account_id
    CARD_PRIMARY_ACCOUNT_ID
  end

  def self.kind_for(account_data)
    return account_data.account_kind if account_data.respond_to?(:account_kind)

    data = account_data.with_indifferent_access
    kind = data[:account_kind].presence || data[:kind].presence || "cash"
    kind.to_s == "credit_card" ? "card" : kind.to_s
  end

  def self.name_for(account_data)
    data = account_data.with_indifferent_access
    kind = kind_for(data)

    if kind == "card"
      data[:name].presence || I18n.t("brex_items.default_card_name", default: "Brex Card")
    else
      data[:name].presence || data[:display_name].presence || I18n.t("brex_items.default_cash_name", id: data[:id], default: "Brex Cash #{data[:id]}")
    end
  end

  def self.currency_for(account_data)
    data = account_data.with_indifferent_access
    currency_code_from_money(data[:current_balance] || data[:available_balance] || data[:account_limit])
  end

  def self.default_account_type_for(account_data)
    kind_for(account_data) == "card" ? "CreditCard" : "Depository"
  end

  def self.default_accountable_attributes(accountable_type)
    case accountable_type
    when "CreditCard"
      { subtype: CreditCard::DEFAULT_SUBTYPE }
    when "Depository"
      { subtype: Depository::DEFAULT_SUBTYPE }
    else
      {}
    end
  end

  def self.money_to_decimal(money_payload)
    return nil if money_payload.blank?

    payload = money_payload.is_a?(Hash) ? money_payload.with_indifferent_access : { amount: money_payload, currency: "USD" }
    amount = payload[:amount]
    return nil if amount.nil?

    currency = currency_code_from_money(payload)
    divisor = Money::Currency.new(currency).minor_unit_conversion
    BigDecimal(amount.to_s) / BigDecimal(divisor.to_s)
  rescue Money::Currency::UnknownCurrencyError, ArgumentError
    Rails.logger.warn("Invalid Brex money payload #{money_payload.inspect}, defaulting conversion to USD")
    begin
      safe_amount = BigDecimal(payload[:amount].to_s)
      safe_amount / BigDecimal(Money::Currency.new("USD").minor_unit_conversion.to_s)
    rescue ArgumentError, TypeError
      BigDecimal("0")
    end
  end

  def self.currency_code_from_money(money_payload)
    payload = money_payload.is_a?(Hash) ? money_payload.with_indifferent_access : {}
    currency = payload[:currency].presence || "USD"
    Money::Currency.new(currency).iso_code
  rescue Money::Currency::UnknownCurrencyError
    "USD"
  end

  def self.sanitize_payload(payload)
    case payload
    when Array
      payload.map { |value| sanitize_payload(value) }
    when Hash
      payload.each_with_object({}) do |(key, value), sanitized|
        key_string = key.to_s
        normalized_key = key_string.downcase

        if sensitive_number_key?(normalized_key)
          sanitized["#{key_string}_last4"] = last_four(value)
        elsif normalized_key == "card_metadata"
          sanitized[key_string] = sanitize_card_metadata(value)
        elsif sensitive_secret_key?(normalized_key)
          sanitized[key_string] = "[FILTERED]"
        else
          sanitized[key_string] = sanitize_payload(value)
        end
      end
    else
      payload
    end
  end

  def self.last_four(value)
    digits = value.to_s.gsub(/\D/, "")
    digits.last(4) if digits.present?
  end

  def self.sanitize_card_metadata(value)
    return nil unless value.is_a?(Hash)

    metadata = value.with_indifferent_access
    {
      "card_id" => metadata[:card_id].presence || metadata[:id].presence,
      "card_name" => metadata[:card_name].presence || metadata[:name].presence,
      "card_type" => metadata[:card_type].presence || metadata[:type].presence,
      "last_four" => last_four(metadata[:last_four].presence || metadata[:last4].presence || metadata[:card_last_four].presence)
    }.compact
  end

  def current_account
    account
  end

  def linked_account
    account
  end

  def cash?
    account_kind == "cash"
  end

  def card?
    account_kind == "card"
  end

  def upsert_brex_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    kind = snapshot[:account_kind].presence || snapshot[:kind].presence || "cash"
    kind = "card" if kind.to_s == "credit_card"

    update!(
      current_balance: self.class.money_to_decimal(snapshot[:current_balance]),
      available_balance: self.class.money_to_decimal(snapshot[:available_balance]),
      account_limit: self.class.money_to_decimal(snapshot[:account_limit]),
      currency: self.class.currency_code_from_money(snapshot[:current_balance] || snapshot[:available_balance] || snapshot[:account_limit]),
      name: self.class.name_for(snapshot.merge(account_kind: kind)),
      account_id: snapshot[:id]&.to_s,
      account_kind: kind,
      account_status: snapshot[:status],
      account_type: snapshot[:type],
      provider: "brex",
      institution_metadata: build_institution_metadata(snapshot, kind),
      raw_payload: self.class.sanitize_payload(account_snapshot)
    )
  end

  def upsert_brex_transactions_snapshot!(transactions_snapshot)
    update!(
      raw_transactions_payload: self.class.sanitize_payload(transactions_snapshot)
    )
  end

  private

    def self.sensitive_number_key?(normalized_key)
      normalized_key.in?(%w[account_number routing_number pan primary_account_number card_number])
    end

    def self.sensitive_secret_key?(normalized_key)
      normalized_key.include?("token") ||
        normalized_key.include?("secret") ||
        normalized_key.in?(%w[api_key access_key authorization cvc cvv security_code])
    end
    private_class_method :sensitive_number_key?, :sensitive_secret_key?

    def build_institution_metadata(snapshot, kind)
      {
        name: "Brex",
        domain: "brex.com",
        url: "https://brex.com",
        account_kind: kind,
        account_type: snapshot[:type],
        primary: snapshot[:primary],
        account_number_last4: self.class.last_four(snapshot[:account_number]),
        routing_number_last4: self.class.last_four(snapshot[:routing_number]),
        status: snapshot[:status],
        current_statement_period: self.class.sanitize_payload(snapshot[:current_statement_period])
      }.compact
    end
end
