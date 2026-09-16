require "bigdecimal"
require "digest/md5"
require "time"

class Provider::AccountData::Up < Provider::AccountData::Adapter
  DEFINITION = Provider::AccountData::Definition.new(
    key: "up", source: "up", credential_scope: "connection",
    capabilities: [ "transactions" ],
    fields: [ { name: "access_token", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.build(credentials:, settings:, context:)
    new(client: Provider::Up.new(credentials.fetch("access_token")), timezone: context.fetch(:timezone))
  end

  def self.native_ready?
    true
  end

  def self.editable_connection_credentials
    [ "access_token" ]
  end

  def self.account_setup_types
    %w[Depository Loan]
  end

  def initialize(client:, timezone:)
    super(client: client)
    @timezone = timezone
  end

  def self.initial_history_metadata_keys
    [ "up_initial_history_start" ]
  end

  # Cutover installs a per-account first-read hint after verifying its retained
  # cache. Explicit user dates and completed checkpoints keep their precedence.
  def initial_history_start(account:, observed_at:)
    metadata = account.fetch(:metadata, {})
    return super unless metadata.key?("up_initial_history_start")

    value = metadata.fetch("up_initial_history_start")
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise Provider::AccountData::InvalidResponse, "Invalid Up initial history date"
    end
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Up initial history date", cause: nil
  end

  def list_accounts(cursor: nil)
    result = client.get_accounts_page(cursor: cursor)
    page(result, kind: "account") { |data| normalize_account(data) }
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    scope = (window || {}).with_indifferent_access
    result = client.get_account_transactions_page(
      account_id: account[:external_id], cursor: cursor,
      since: scope[:start], until_date: scope[:end]
    )
    page(result, kind: "transaction", coverage: scope.to_h) do |data|
      normalize_transaction(data, account: account)
    end
  end

  # Public normalization is shared by migration parity tests and network reads.
  def normalize_account(raw)
    data = raw.with_indifferent_access
    balance = data.fetch(:balance).with_indifferent_access
    Ingestion::Record.account(
      external_id: data.fetch(:id),
      name: data[:displayName].presence || I18n.t("up_account.fallback"),
      currency: currency(balance.fetch(:currencyCode)),
      account_type: data[:accountType], balance: decimal(balance.fetch(:value)),
      metadata: {
        institution: { name: "Up", domain: "up.com.au" },
        ownership_type: data[:ownershipType],
        balance_policy: { debt_transform: "absolute", debt_types: [ "Loan" ], cash_balance: "balance" }
      }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Up account", cause: nil
  end

  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    unless data[:account_id].is_a?(String) && data[:account_id].present? && data[:account_id] == account[:external_id]
      raise Provider::AccountData::InvalidResponse, "Up transaction belongs to another account"
    end
    amount = data.fetch(:amount).with_indifferent_access
    foreign = data[:foreignAmount].is_a?(Hash) ? data[:foreignAmount].with_indifferent_access : {}
    description = data[:description].to_s.strip.presence
    transfer = data[:transfer_account_id].presence
    pending = data[:status].to_s.upcase == "HELD"
    unless %w[HELD SETTLED].include?(data[:status].to_s.upcase)
      raise Provider::AccountData::InvalidResponse, "Unknown Up transaction status"
    end
    Ingestion::Record.transaction(
      external_id: external_id(data),
      name: data[:description].presence || I18n.t("transactions.unknown_name"),
      amount: -decimal(amount.fetch(:value)),
      currency: currency(amount[:currencyCode], fallback: account[:currency]),
      date: transaction_date(data[:settledAt].presence || data[:createdAt]),
      pending: pending,
      metadata: {
        notes: data[:message].presence, kind: transfer ? "funds_movement" : nil,
        category_slug: data[:category_id],
        merchant: description ? { external_id: "up_merchant_#{Digest::MD5.hexdigest(description.downcase)}", name: description } : nil,
        extra: { "up" => {
          "pending" => pending, "status" => data[:status], "category_id" => data[:category_id],
          "transfer_account_id" => transfer, "raw_text" => data[:rawText],
          "fx_from" => foreign[:currencyCode], "fx_amount" => foreign[:value]
        }.compact }
      }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Up transaction", cause: nil
  end

  private
    attr_reader :timezone

    def page(result, kind:, coverage: {})
      unless result.is_a?(Hash) && result[:items].is_a?(Array) && result.key?(:next_cursor)
        raise Provider::AccountData::InvalidResponse, "Invalid Up page"
      end
      cursor = result[:next_cursor]
      unless cursor.nil? || (cursor.is_a?(String) && cursor.present?)
        raise Provider::AccountData::InvalidResponse, "Invalid Up page cursor"
      end
      Provider::AccountData::Page.new(
        records: result[:items].map { |raw| yield raw }, mode: "snapshot",
        next_cursor: result[:next_cursor], complete: result[:next_cursor].nil?,
        coverage: coverage.merge("resource" => kind),
        evidence: { "response" => result[:evidence] || { "items" => result[:items] } }
      )
    rescue ArgumentError, TypeError, NoMethodError
      raise Provider::AccountData::InvalidResponse, "Invalid Up page", cause: nil
    end

    def decimal(value)
      raise ArgumentError unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(BigDecimal)
      parsed = BigDecimal(value.to_s)
      raise ArgumentError unless parsed.finite?
      parsed
    end

    def currency(value, fallback: nil)
      known_currency(value) || known_currency(fallback) || raise(ArgumentError, "Invalid currency")
    end

    def known_currency(value)
      return unless value.is_a?(String)

      normalized = value.strip.upcase
      return unless normalized.match?(/\A[A-Z]{3}\z/)

      Money::Currency.new(normalized)
      normalized
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    def transaction_date(value)
      return value if value.instance_of?(Date)
      return value.in_time_zone(timezone).to_date if value.is_a?(Time) || value.is_a?(DateTime)
      if value.is_a?(Integer) || value.is_a?(Float)
        raise ArgumentError unless value.finite?
        return Time.at(value).in_time_zone(timezone).to_date
      end
      raise ArgumentError unless value.is_a?(String) && value.present?
      return Date.iso8601(value) unless value.match?(/[T:]/)

      raise ArgumentError unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Date.iso8601(value.split("T", 2).first)
      Time.iso8601(value).in_time_zone(timezone).to_date
    end

    def external_id(data)
      raise ArgumentError unless data[:id].nil? || data[:id].is_a?(String)
      return "up_#{data[:id]}" if data[:id].present?
      values = [ data[:account_id], data[:createdAt], data.dig(:amount, :value), data[:description] ]
      "up_pending_#{Digest::MD5.hexdigest(values.compact.join('|'))}"
    end
end
