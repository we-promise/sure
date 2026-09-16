require "bigdecimal"
require "digest/md5"
require "time"

class Provider::AccountData::Lunchflow < Provider::AccountData::Adapter
  DEFINITION = Provider::AccountData::Definition.new(
    key: "lunchflow", source: "lunchflow", credential_scope: "connection",
    capabilities: %w[transactions holdings], fields: [
      { name: "api_key", type: "text", secret: true },
      { name: "base_url", type: "string", secret: false, default: "https://lunchflow.app/api/v1" }
    ]
  )

  def self.definition
    DEFINITION
  end

  def self.runtime_options
    %i[include_pending]
  end

  def self.build(credentials:, settings:, context:)
    new(client: Provider::Lunchflow.new(credentials.fetch("api_key"), base_url: settings.fetch("base_url", "https://lunchflow.app/api/v1")),
      timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      include_pending: context.fetch(:configured_options).fetch(:include_pending))
  end

  # Remains gated until shared temporary-ID collision/reconciliation and holdings
  # support have passed parity checks. No legacy processor is used at runtime.
  def initialize(client:, timezone:, observed_at:, include_pending:)
    super(client: client)
    raise ArgumentError, "include_pending must be explicit" unless [ true, false ].include?(include_pending)
    raise ArgumentError, "An observation time is required" unless observed_at.is_a?(Date) || observed_at.is_a?(Time)
    @timezone = timezone
    @observed_date = observed_at.to_date
    @include_pending = include_pending
  end

  def list_accounts(cursor: nil)
    reject_cursor!(cursor)
    response = client.get_accounts_snapshot
    collection_page(response, collection: :accounts, kind: "account") { |raw| normalize_account(raw) }
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    reject_cursor!(cursor)
    scope = (window || {}).with_indifferent_access
    from = request_date(scope[:start])
    through = request_date(scope[:end])
    raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow date window" if from && through && from > through
    response = client.get_account_transactions_snapshot(account[:external_id],
      start_date: from, end_date: through, include_pending: include_pending)
    collection_page(response, collection: :transactions, kind: "transaction", coverage: {
      "start" => from&.to_time(:utc)&.iso8601, "end" => through&.to_time(:utc)&.end_of_day&.iso8601,
      "pending_included" => include_pending, "pending_absence_authoritative" => false
    }.compact) { |raw| normalize_transaction(raw, account: account) }
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    reject_cursor!(cursor)
    response = client.get_account_balance_snapshot(account[:external_id])
    raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow balance envelope" unless response.is_a?(Hash)
    warnings = []
    record = begin
      normalize_balance(response, account: account)
    rescue Provider::AccountData::InvalidResponse
      warnings << warning("invalid_balance")
      nil
    end
    Provider::AccountData::Page.new(records: [ record ].compact, complete: warnings.empty?, mode: "snapshot",
      warnings: warnings, coverage: { "resource" => "balance" }, evidence: { "response" => response })
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    reject_cursor!(cursor)
    response = client.get_account_holdings_snapshot(account[:external_id])
    if response.is_a?(Hash) && response.with_indifferent_access[:holdings_not_supported] == true
      return Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
        warnings: [ warning("holdings_not_supported") ], evidence: { "response" => response },
        coverage: { "resource" => "holding", "supported" => false, "absence_authoritative" => false })
    end
    collection_page(response, collection: :holdings, kind: "holding", coverage: {
      "observed_date" => observed_date.to_s, "absence_authoritative" => false, "delete_future_holdings" => false
    }) { |raw| normalize_holding(raw, account: account) }
  end

  def normalize_account(raw)
    data = raw.with_indifferent_access
    supplied_currency = known_currency(data[:currency])
    name = data[:institution_name].present? ? "#{data[:institution_name]} - #{data.fetch(:name)}" : data.fetch(:name)
    Ingestion::Record.account(
      external_id: identifier(data.fetch(:id)), name: name, currency: supplied_currency, balance: nil,
      metadata: {
        balance_provided: false,
        account_status: data[:status], downstream_provider: data[:provider],
        institution: { name: data[:institution_name], logo: data[:institution_logo] }.compact,
        balance_policy: balance_policy
      }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow account", cause: nil
  end

  def normalize_balance(raw, account:)
    data = raw.with_indifferent_access
    balance = data.fetch(:balance).with_indifferent_access
    metadata = (account[:metadata] || {}).with_indifferent_access
    fallback = known_currency(account[:currency])
    currency = known_currency(balance[:currency]) || fallback || raise(ArgumentError)
    Ingestion::Record.account(
      external_id: account[:external_id], name: account[:name], account_type: account[:account_type],
      currency: currency, balance: decimal(balance.fetch(:amount)),
      metadata: metadata.merge(balance_provided: true, balance_policy: balance_policy).deep_symbolize_keys
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow balance", cause: nil
  end

  def normalize_legacy_account(raw)
    normalize_account(raw)
  end

  def normalize_legacy_transaction(raw, account:)
    normalize_transaction(legacy_monetary_values(raw, %w[amount]), account: account)
  end

  def normalize_legacy_balance(raw, account:)
    data = raw.deep_dup.with_indifferent_access
    data[:balance] = legacy_monetary_values(data[:balance], %w[amount])
    normalize_balance(data, account: account)
  end

  def normalize_legacy_holding(raw, account:)
    normalize_holding(legacy_monetary_values(raw, %w[quantity value price costBasis]), account: account)
  end

  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    if data[:accountId].present? && identifier(data[:accountId]) != account[:external_id]
      raise ArgumentError
    end
    pending = !!ActiveModel::Type::Boolean.new.cast(data[:isPending])
    return nil if pending && !include_pending
    temporary = data[:id].blank?
    id = if temporary
      "lunchflow_pending_#{Digest::MD5.hexdigest(%i[accountId amount currency date merchant description].filter_map { |key| identity_scalar(data[key]) }.join('|'))}"
    else
      "lunchflow_#{identifier(data[:id])}"
    end
    merchant = data[:merchant].to_s.strip.presence
    extra = data.key?(:isPending) ? { "lunchflow" => { "pending" => ActiveModel::Type::Boolean.new.cast(data[:isPending]) } } : {}
    Ingestion::Record.transaction(
      external_id: id, name: data[:merchant].presence || "Unknown transaction",
      amount: -decimal(data.fetch(:amount)), currency: known_currency(data[:currency]) || account[:currency],
      date: transaction_date(data.fetch(:date)), pending: pending,
      metadata: {
        extra: extra, pending_provided: data.key?(:isPending), notes: data[:description].presence,
        merchant: merchant ? { external_id: "lunchflow_merchant_#{Digest::MD5.hexdigest(merchant.downcase)}", name: merchant } : nil,
        identity_policy: temporary ? "reuse_pending_or_allocate_suffix" : nil,
        pending_match_policy: !pending && !temporary ? { source: "lunchflow", backward_days: 8, amount: "exact", currency: "exact" } : nil,
        posted_match_policy: pending && temporary ? { source: "lunchflow", forward_days: 8,
          amount: "exact", currency: "exact", name: data[:merchant].present? ? "exact" : nil,
          exclude_external_id_prefix: "lunchflow_pending_" } : nil
      }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow transaction", cause: nil
  end

  def normalize_holding(raw, account:)
    data = raw.with_indifferent_access
    security = data.fetch(:security).with_indifferent_access
    source = data[:raw]
    ids = if source.is_a?(Hash)
      source.values.filter_map do |provider|
        next unless provider.is_a?(Hash)
        value = provider.with_indifferent_access[:id]
        identifier(value) if value.present?
      end.uniq
    else
      []
    end
    raise ArgumentError if ids.size > 1
    id = ids.first
    id ||= Digest::MD5.hexdigest([ security[:tickerSymbol], security[:name], data[:quantity], data[:value] ]
      .filter_map { |value| identity_scalar(value) }.join("-"))[0, 12]
    name = security[:name].to_s.strip
    ticker = security[:tickerSymbol].presence
    if ticker.blank? && name.present?
      ticker = "CUSTOM:#{name.gsub(/[^a-zA-Z0-9]/, '_').upcase[0, 24]}_#{Digest::MD5.hexdigest(name)[0, 5].upcase}"
    end
    raise ArgumentError unless ticker.is_a?(String) && ticker.present?
    ticker = ticker.upcase
    linked_type = (account[:metadata] || {}).with_indifferent_access[:linked_account_type] || account[:account_type]
    crypto = linked_type == "Crypto" || %w[BTC ETH SOL DOGE LTC BCH XRP ADA DOT AVAX].include?(ticker)
    ticker = "CRYPTO:#{ticker}" if crypto && !ticker.include?(":")
    quantity = holding_decimal(data[:quantity])
    amount = holding_decimal(data[:value])
    return nil if quantity.zero? && amount.zero?
    Ingestion::Record.holding(
      external_id: "lunchflow_#{id}", quantity: quantity, amount: amount, price: holding_decimal(data[:price]),
      date: observed_date, currency: known_currency(data[:currency]) || known_currency(security[:currency]) || "USD",
      security: { ticker: ticker, name: name.presence, offline: ticker.start_with?("CUSTOM:"), fallback_offline: true },
      metadata: { cost_basis: holding_decimal(data[:costBasis]), delete_future_holdings: false }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow holding", cause: nil
  end

  private
    attr_reader :timezone, :observed_date, :include_pending

    def reject_cursor!(cursor)
      raise Provider::AccountData::InvalidResponse, "Lunch Flow endpoint has no continuation cursor" unless cursor.nil?
    end

    def collection_page(response, collection:, kind:, coverage: {})
      raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow envelope" unless response.is_a?(Hash)
      data = response.with_indifferent_access
      raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow collection" unless data[collection].is_a?(Array)
      warnings = []
      if data.key?(:total) && (!data[:total].is_a?(Integer) || data[:total] != data[collection].size)
        warnings << warning("reported_total_mismatch")
      end
      if data[:nextCursor].present? || data[:next_cursor].present? || data[:hasMore] == true || data[:has_more] == true
        warnings << warning("unsupported_continuation")
      end
      warnings << warning("provider_error") if data[:error].present? || data[:errors].present?
      occurrences = Hash.new(0)
      records = data[collection].filter_map do |row|
        record = yield row
        if record && record[:metadata]&.dig(:identity_policy) == "reuse_pending_or_allocate_suffix"
          occurrence = occurrences[record[:external_id]]
          occurrences[record[:external_id]] += 1
          record = Ingestion::Record.transaction(**record.attributes.merge(
            metadata: record[:metadata].merge(identity_occurrence: occurrence)))
        end
        record
      rescue Provider::AccountData::InvalidResponse
        warnings << warning("invalid_#{kind}")
        nil
      end
      # Blank IDs may intentionally collide and require the ledger's occurrence
      # policy. Never silently deduplicate identical economic events here.
      Provider::AccountData::Page.new(records: records, complete: warnings.empty?, mode: "snapshot", warnings: warnings,
        coverage: coverage.merge("resource" => kind), evidence: { "response" => response })
    end

    def balance_policy
      { debt_transform: "negate", debt_types: %w[CreditCard Loan], cash_balance: "balance" }
    end

    def warning(code)
      { "provider" => "lunchflow", "code" => code, "scope" => "response" }
    end

    def decimal(value)
      raise ArgumentError unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(BigDecimal)
      parsed = BigDecimal(value.to_s)
      raise ArgumentError unless parsed.finite?
      parsed
    end

    def legacy_monetary_values(raw, fields)
      raise Provider::AccountData::InvalidResponse, "Invalid legacy Lunch Flow record" unless raw.is_a?(Hash)
      raw.deep_dup.with_indifferent_access.tap do |data|
        fields.each do |field|
          value = data[field]
          next unless value.is_a?(Float)
          raise Provider::AccountData::InvalidResponse, "Invalid legacy Lunch Flow number" unless value.finite?
          data[field] = BigDecimal(value.to_s)
        end
      end
    end

    def holding_decimal(value)
      value.nil? || value == "" ? BigDecimal("0") : decimal(value)
    end

    # Legacy JSONB decoding used Float#to_s inside content IDs. Reproduce that
    # spelling for identity only; all monetary calculation stays in BigDecimal.
    # Strings retain their original spelling, including trailing fractional zeros.
    def identity_scalar(value)
      return nil if value.nil?
      return value.to_f.to_s if value.is_a?(BigDecimal)
      raise ArgumentError unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Date) || value.is_a?(Time)
      raise ArgumentError if value.is_a?(Float) && !value.finite?
      value.to_s
    end

    def identifier(value)
      raise ArgumentError unless value.is_a?(String) || value.is_a?(Integer)
      raise ArgumentError if value.to_s.strip.empty?
      value.to_s
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
      if value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal)
        raise ArgumentError unless value.finite?
        return Time.at(value).in_time_zone(timezone).to_date
      end
      raise ArgumentError unless value.is_a?(String) && value.present?
      return Date.iso8601(value) unless value.match?(/[T:]/)
      raise ArgumentError unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Date.iso8601(value.split("T", 2).first)
      Time.iso8601(value).in_time_zone(timezone).to_date
    end

    def request_date(value)
      return nil if value.nil?
      return value.to_date if value.is_a?(Time) || value.is_a?(Date)
      raise ArgumentError unless value.is_a?(String)
      value.include?("T") ? Time.iso8601(value).to_date : Date.iso8601(value)
    rescue ArgumentError, TypeError
      raise Provider::AccountData::InvalidResponse, "Invalid Lunch Flow request date", cause: nil
    end
end
