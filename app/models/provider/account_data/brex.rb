require "base64"
require "digest/md5"
require "json"

class Provider::AccountData::Brex < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  CARD_ACCOUNT_ID = "card_primary"
  MAX_INVENTORY_PAGES = 25
  DEFINITION = Provider::AccountData::Definition.new(
    key: "brex", source: "brex", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "token", type: "text", secret: true }, { name: "base_url", type: "string", secret: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.editable_connection_credentials
    [ "token" ]
  end

  def self.account_setup_types
    %w[Depository CreditCard]
  end

  def self.build(credentials:, settings:, context:)
    client = Provider::Brex.new(
      credentials.with_indifferent_access.fetch(:token),
      base_url: settings.with_indifferent_access[:base_url].presence || Provider::Brex::DEFAULT_BASE_URL
    )
    new(client: client, timezone: context.fetch(:timezone))
  end

  def initialize(client:, timezone:)
    super(client: client)
    @timezone = timezone
  end

  def self.initial_history_metadata_keys
    [ "brex_initial_history_start" ]
  end

  def initial_history_start(account:, observed_at:)
    metadata = account.fetch(:metadata, {})
    return super unless metadata.key?("brex_initial_history_start")

    value = metadata.fetch("brex_initial_history_start")
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise Provider::AccountData::InvalidResponse, "Invalid Brex initial history date"
    end
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Brex initial history date", cause: nil
  end

  # Brex exposes physical card accounts, but its transaction feed spans all cards.
  # Retain the existing single card_primary identity. Partial aggregates travel in
  # the encrypted page continuation so a retry never relies on adapter memory.
  def list_accounts(cursor: nil)
    state = decode_inventory_cursor(cursor)
    result = checked_page(state.fetch("phase") == "cash" ?
      client.get_cash_accounts_page(cursor: state["cursor"]) : client.get_card_accounts_page(cursor: state["cursor"]))
    if state.fetch("phase") == "cash"
      records = result[:items].map { |raw| normalize_account(raw.merge(account_kind: "cash")) }
      continuation = result[:next_cursor] ? inventory_cursor(advance_inventory(state, result[:next_cursor])) : inventory_cursor(initial_inventory("card"))
      Provider::AccountData::Page.new(records: records, complete: false, mode: "snapshot", next_cursor: continuation,
        evidence: { "phase" => "cash", "response" => result[:evidence] || { items: result[:items] } })
    else
      aggregate = aggregate_cards(result[:items], state.fetch("aggregate", {}))
      if result[:next_cursor]
        next_state = advance_inventory(state, result[:next_cursor]).merge("aggregate" => aggregate)
        Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot", next_cursor: inventory_cursor(next_state),
          evidence: { "phase" => "card", "response" => result[:evidence] || { items: result[:items] } })
      else
        records = aggregate.fetch("count", 0).positive? ? [ normalize_account(aggregate_snapshot(aggregate)) ] : []
        Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot",
          evidence: { "phase" => "card", "response" => result[:evidence] || { items: result[:items] } })
      end
    end
  rescue ArgumentError, TypeError, NoMethodError, KeyError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Brex account inventory", cause: nil
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    scope = (window || {}).with_indifferent_access
    result = if account_kind(account) == "card"
      client.get_primary_card_transactions_page(cursor: cursor, start_date: scope[:start])
    else
      client.get_cash_transactions_page(account[:external_id], cursor: cursor, start_date: scope[:start])
    end
    result = checked_page(result)
    Provider::AccountData::Page.new(
      records: result[:items].map { |raw| normalize_transaction(raw, account: account) }, mode: "delta",
      next_cursor: result[:next_cursor], complete: result[:next_cursor].nil?,
      coverage: { "start" => scope[:start], "requested_end" => scope[:end], "server_filter" => "posted_at_start", "resource" => "transaction" }.compact,
      evidence: { "response" => result[:evidence] || { items: result[:items] } }
    )
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Brex transaction page", cause: nil
  end

  def normalize_account(raw)
    data = raw.with_indifferent_access
    kind = data[:account_kind].presence || data[:kind].presence || "cash"
    kind = "card" if kind == "credit_card"
    raise ArgumentError unless %w[cash card].include?(kind)
    currency = money_currency(data[:current_balance])
    balance = money_to_decimal(data.fetch(:current_balance))
    available_balance = data[:available_balance].nil? ? nil : money_to_decimal(data[:available_balance])
    account_limit = data[:account_limit].nil? ? nil : money_to_decimal(data[:account_limit])
    [ data[:available_balance], data[:account_limit] ].compact.each do |money|
      raise ArgumentError unless money_currency(money) == currency
    end
    name = if kind == "card"
      data[:name].presence || I18n.t("brex_items.default_card_name", default: "Brex Card")
    else
      data[:name].presence || data[:display_name].presence || I18n.t("brex_items.default_cash_name", id: data[:id], default: "Brex Cash #{data[:id]}")
    end
    Ingestion::Record.account(
      external_id: data.fetch(:id), name: name, currency: currency, account_type: data[:type],
      balance: balance, cash_balance: balance, available_balance: available_balance,
      metadata: {
        institution: { name: "Brex", domain: "brex.com", url: "https://brex.com" },
        account_kind: kind, account_status: data[:status], primary: data[:primary],
        card_accounts_count: data[:card_accounts_count], account_limit: account_limit&.to_s("F"),
        balance_policy: { debt_transform: "preserve", debt_types: [], cash_balance: "balance", available_credit: "available_balance" }
      }.compact,
      sensitive_details: {
        account_number_last4: last_four(data[:account_number]), routing_number_last4: last_four(data[:routing_number]),
        current_statement_period: sanitize_payload(data[:current_statement_period])
      }.compact
    )
  rescue ArgumentError, TypeError, NoMethodError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid Brex account", cause: nil
  end

  # Only migration parity may convert historical floating-point cache values.
  # Native responses contain integer minor units and never use this entry point.
  def normalize_legacy_account(raw)
    data = raw.with_indifferent_access.deep_dup
    %i[current_balance available_balance account_limit].each do |field|
      data[field] = legacy_money(data[field]) if data.key?(field)
    end
    normalize_account(data)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Brex account", cause: nil
  end

  def normalize_legacy_transaction(raw, account:)
    data = raw.with_indifferent_access.deep_dup
    data[:amount] = legacy_money(data[:amount]) if data.key?(:amount)
    normalize_transaction(data, account: account)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Brex transaction", cause: nil
  end

  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    kind = account_kind(account)
    if kind == "cash" && data[:account_id].present? && data[:account_id] != account[:external_id]
      raise ArgumentError, "Transaction ownership mismatch"
    end
    id = data.fetch(:id)
    raise ArgumentError unless id.is_a?(String) && id.present?
    amount = money_to_decimal(data.fetch(:amount))
    amount_payload = data[:amount].is_a?(Hash) ? data[:amount].with_indifferent_access : {}
    currency = known_currency(amount_payload[:currency]) || known_currency(account[:currency]) || "USD"
    merchant_data = data[:merchant].is_a?(Hash) ? data[:merchant].with_indifferent_access : {}
    merchant_name = (merchant_data[:raw_descriptor].presence || merchant_data[:name].presence).to_s.strip.presence
    merchant = merchant_name && { external_id: "brex_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}", name: merchant_name }
    note_parts = [ data[:type], data[:expense_id] ].select(&:present?)
    extra = {
      transaction_id: id, account_kind: kind, type: data[:type], card_id: data[:card_id],
      transfer_id: data[:transfer_id], expense_id: data[:expense_id],
      card_transaction_operation_reference_id: data[:card_transaction_operation_reference_id],
      initiated_at_date: data[:initiated_at_date], posted_at_date: data[:posted_at_date],
      merchant: sanitize_payload(data[:merchant])
    }.compact
    Ingestion::Record.transaction(
      external_id: "brex_#{id}", amount: amount, currency: currency,
      date: date_in_zone(data[:posted_at_date].presence || data[:initiated_at_date].presence),
      name: data[:description].presence || merchant_data[:raw_descriptor].presence || merchant_data[:name].presence || I18n.t("brex_items.entries.default_name"),
      pending: false,
      metadata: {
        kind: kind == "card" && data[:type] == "COLLECTION" && amount.negative? ? "cc_payment" : nil,
        merchant: merchant, notes: note_parts.any? ? note_parts.join(" - ") : nil, extra: { brex: extra }
      }
    )
  rescue ArgumentError, TypeError, NoMethodError, KeyError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Brex transaction", cause: nil
  end

  private
    attr_reader :timezone

    def account_kind(account)
      kind = (account[:metadata] || {}).with_indifferent_access[:account_kind]
      kind ||= account[:external_id] == CARD_ACCOUNT_ID ? "card" : "cash"
      raise ArgumentError unless %w[cash card].include?(kind)
      kind
    end

    def money_currency(value)
      payload = value.is_a?(Hash) ? value.with_indifferent_access : {}
      known_currency(payload[:currency]) || "USD"
    end

    def legacy_money(value)
      if value.is_a?(Hash)
        data = value.with_indifferent_access.deep_dup
        data[:amount] = legacy_money(data[:amount]) if data.key?(:amount)
        data
      elsif value.is_a?(Float)
        raise ArgumentError unless value.finite?
        BigDecimal(value.to_s)
      else
        value
      end
    end

    def minor_amount(value)
      amount = value.is_a?(Hash) ? value.with_indifferent_access.fetch(:amount) : value
      result = decimal(amount)
      raise ArgumentError unless result.frac.zero?
      result
    end

    def money_to_decimal(value)
      minor_amount(value) / BigDecimal(Money::Currency.new(money_currency(value)).minor_unit_conversion.to_s)
    end

    def initial_inventory(phase)
      { "v" => 1, "phase" => phase, "cursor" => nil, "seen" => [], "pages" => 0 }
    end

    def decode_inventory_cursor(cursor)
      return initial_inventory("cash") if cursor.nil?
      raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 262_144
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless state.is_a?(Hash) && state["v"] == 1 && %w[cash card].include?(state["phase"]) &&
          (state["cursor"].nil? || (state["cursor"].is_a?(String) && state["cursor"].present?)) &&
          state["pages"].is_a?(Integer) && (0...MAX_INVENTORY_PAGES).cover?(state["pages"]) &&
          state["seen"].is_a?(Array) && state["seen"].all? { |value| value.is_a?(String) }
        raise ArgumentError
      end
      state
    end

    def advance_inventory(state, next_cursor)
      if state.fetch("seen").include?(next_cursor) || state.fetch("pages") + 1 >= MAX_INVENTORY_PAGES
        raise Provider::AccountData::IncompletePage, "Brex inventory pagination did not finish"
      end
      state.merge("cursor" => next_cursor, "seen" => state.fetch("seen") + [ next_cursor ], "pages" => state.fetch("pages") + 1)
    end

    def inventory_cursor(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def aggregate_cards(rows, previous)
      raise ArgumentError unless previous.is_a?(Hash)
      aggregate = previous.deep_dup
      aggregate["count"] ||= 0
      rows.each do |row|
        data = row.with_indifferent_access
        # Missing current balances cannot become a partial aggregate presented as
        # the complete company card balance.
        minor_amount(data.fetch(:current_balance))
        aggregate["status"] ||= data[:status]
        aggregate["count"] += 1
        %w[current_balance available_balance account_limit].each do |field|
          money = data[field]
          next if money.nil?
          currency = money_currency(money)
          existing = aggregate[field]
          if existing && existing.fetch("currency") != currency
            raise Provider::AccountData::InvalidResponse, "Brex card aggregation has mixed currencies"
          end
          amount = minor_amount(money) + (existing ? decimal(existing.fetch("amount")) : BigDecimal("0"))
          aggregate[field] = { "amount" => amount.to_s("F"), "currency" => currency }
        end
      end
      aggregate
    end

    def aggregate_snapshot(aggregate)
      aggregate.slice("current_balance", "available_balance", "account_limit", "status").merge(
        "id" => CARD_ACCOUNT_ID, "name" => "Brex Card", "account_kind" => "card", "card_accounts_count" => aggregate.fetch("count")
      )
    end

    def last_four(value)
      digits = value.to_s.gsub(/\D/, "")
      digits.last(4) if digits.present?
    end

    # Same retained merchant fields as the legacy Brex processor, with no model
    # dependency. Full card numbers and credentials never reach Transaction.extra.
    def sanitize_payload(payload)
      case payload
      when Array
        payload.map { |value| sanitize_payload(value) }
      when Hash
        payload.each_with_object({}) do |(key, value), sanitized|
          normalized = key.to_s.downcase
          if %w[account_number routing_number pan primary_account_number card_number].include?(normalized)
            sanitized["#{key}_last4"] = last_four(value)
          elsif normalized == "card_metadata"
            data = value.is_a?(Hash) ? value.with_indifferent_access : {}
            sanitized[key.to_s] = {
              "card_id" => data[:card_id].presence || data[:id].presence,
              "card_name" => data[:card_name].presence || data[:name].presence,
              "card_type" => data[:card_type].presence || data[:type].presence,
              "last_four" => last_four(data[:last_four].presence || data[:last4].presence || data[:card_last_four].presence)
            }.compact if value.is_a?(Hash)
            sanitized[key.to_s] = nil unless value.is_a?(Hash)
          elsif normalized.include?("token") || normalized.include?("secret") || %w[api_key access_key authorization cvc cvv security_code].include?(normalized)
            sanitized[key.to_s] = "[FILTERED]"
          else
            sanitized[key.to_s] = sanitize_payload(value)
          end
        end
      else
        payload
      end
    end
end
