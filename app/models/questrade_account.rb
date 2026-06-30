# frozen_string_literal: true

class QuestradeAccount < ApplicationRecord
  include CurrencyNormalizable
  include QuestradeAccount::DataHelpers

  belongs_to :questrade_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }


  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  def upsert_from_questrade!(account_data)
    # Convert SDK object to hash if needed
    data = sdk_object_to_hash(account_data).with_indifferent_access

    # Questrade's list_accounts returns: number, type (TFSA/RRSP/Margin/Cash...),
    # status, clientAccountType, isPrimary, isBilling. There's no friendly name,
    # so we build one from the type + number.
    number = (data[:number] || data[:id]).to_s
    type = data[:type].presence || "Account"

    update!(
      questrade_account_id: number,
      name: "#{type} (#{number})",
      # Questrade accounts are CAD-based; per-currency sub-balances and per-security
      # values are handled by Sure's securities pricing, not this field.
      currency: "CAD",
      account_status: data[:status],
      account_type: type,
      provider: "Questrade",
      institution_metadata: { name: "Questrade", domain: "questrade.com" },
      raw_payload: data
    )
  end

  # Store holdings snapshot - return early if empty to avoid setting timestamps incorrectly
  def upsert_holdings_snapshot!(holdings_data)
    return if holdings_data.blank?

    update!(
      raw_holdings_payload: holdings_data,
      last_holdings_sync: Time.current
    )
  end

  # Store activities snapshot - return early if empty to avoid setting timestamps incorrectly
  def upsert_activities_snapshot!(activities_data)
    return if activities_data.blank?

    update!(
      raw_activities_payload: activities_data,
      last_activities_sync: Time.current
    )
  end

  # Store per-currency balances. Primary (account currency) cash goes in
  # cash_balance; the full set is kept so the processor can surface
  # non-primary-currency cash as holdings (issue #1809).
  def upsert_balances!(per_currency_balances)
    data = Array(per_currency_balances).map { |b| sdk_object_to_hash(b).with_indifferent_access }
    primary = primary_cash_entry(data)
    cash_value = primary ? primary[:cash] : 0
    update!(cash_balance: cash_value, raw_balances_payload: data)
  end

  # Cash held in currencies other than the account's primary currency, surfaced
  # as synthetic cash holdings (issue #1809). Primary cash lives in cash_balance.
  def non_primary_cash_entries
    entries = Array(raw_balances_payload).map do |e|
      e.respond_to?(:with_indifferent_access) ? e.with_indifferent_access : {}
    end
    entries.filter_map do |e|
      code = e[:currency]
      next if code.blank? || code == currency
      amount = e[:cash]
      next if amount.blank? || amount.to_d.abs < BigDecimal("0.01")
      { currency: code, amount: amount }
    end
  end

  private

    # Primary cash entry: account currency first, then USD, then first entry.
    def primary_cash_entry(entries)
      entries = entries.map { |e| e.respond_to?(:with_indifferent_access) ? e.with_indifferent_access : {} }
      # Only the account-currency (CAD) entry is primary; other currencies
      # surface as separate cash holdings.
      entries.find { |b| b[:currency] == currency }
    end

    def extract_institution_metadata(data)
      {
        name: data[:institution_name] || data.dig(:institution, :name),
        logo: data[:institution_logo] || data.dig(:institution, :logo),
        domain: data[:institution_domain] || data.dig(:institution, :domain)
      }.compact
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Questrade account #{id}, defaulting to USD")
    end
end
