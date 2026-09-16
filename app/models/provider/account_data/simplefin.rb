require "base64"
require "bigdecimal"
require "digest/md5"
require "json"
require "time"
require "uri"

# One access URL may cover many institutions. Each HTTP response is one complete
# protocol envelope; transaction continuation is an explicitly bounded time
# window, never an invented upstream cursor or an institution-shaped connection.
class Provider::AccountData::Simplefin < Provider::AccountData::Adapter
  DEFINITION = Provider::AccountData::Definition.new(
    key: "simplefin", source: "simplefin", credential_scope: "connection",
    capabilities: %w[transactions holdings],
    fields: [ { name: "access_url", type: "text", secret: true } ]
  )
  WINDOW_SECONDS = 60 * 24 * 60 * 60
  CACHE_SIZE = 4
  TOTAL_BASIS_INSTITUTIONS = %w[vanguard fidelity schwab].freeze
  MONEY_MARKET_TICKERS = %w[VMFXX VMMXX VMRXX VUSXX SPAXX FDRXX SPRXX FZFXX FDLXX SWVXX SNVXX SNOXX TTTXX PRTXX].freeze
  MONEY_MARKET_PATTERNS = [ /money\s*market/i, /settlement\s*fund/i, /cash\s*reserve/i ].freeze

  def self.definition
    DEFINITION
  end

  def self.build(credentials:, settings:, context:)
    configured = context.fetch(:configured_options)
    new(client: Provider::Simplefin.new, access_url: credentials.fetch("access_url"),
      include_pending: context.fetch(:pending_override) ? configured.fetch(:include_pending) : context.fetch(:pending_preference),
      observed_at: context.fetch(:observed_at),
      money_market_tickers: configured.fetch(:money_market_tickers, MONEY_MARKET_TICKERS),
      money_market_patterns: configured.fetch(:money_market_patterns, MONEY_MARKET_PATTERNS),
      policy_snapshots: context.fetch(:simplefin_balance_classification))
  end

  def self.runtime_options
    %i[include_pending money_market_tickers money_market_patterns]
  end

  def self.external_account_inputs
    { mutable: [], frozen: [], inventory: "linked" }
  end

  def self.frozen_context_sources
    [ :simplefin_balance_classification ]
  end

  def self.context_sources
    %i[simplefin_balance_classification]
  end

  def account_stream_dependencies
    { "balances" => [ "transactions" ] }
  end

  # Keep the inherited native_ready? false until migration, lifecycle and runtime
  # parity acceptance (including the staged credit classifier) have passed.
  def initialize(client:, access_url:, include_pending:, observed_at:, money_market_tickers: MONEY_MARKET_TICKERS, money_market_patterns: MONEY_MARKET_PATTERNS, policy_snapshots: {})
    super(client: client)
    raise ArgumentError, "include_pending must be resolved explicitly" unless [ true, false ].include?(include_pending)
    raise ArgumentError, "An observation time is required" unless observed_at.is_a?(Date) || observed_at.is_a?(Time)
    raise ArgumentError, "Money market rules must be arrays" unless money_market_tickers.is_a?(Array) && money_market_patterns.is_a?(Array)
    @access_url = access_url
    @include_pending = include_pending
    @observed_date = observed_at.to_date
    @money_market_tickers = money_market_tickers.map(&:upcase).freeze
    @money_market_patterns = money_market_patterns.dup.freeze
    @policy_snapshots = policy_snapshots.deep_dup
    @responses = {}
  end

  def list_accounts(cursor: nil)
    raise Provider::AccountData::InvalidResponse, "SimpleFIN inventory has no continuation cursor" unless cursor.nil?
    data, warnings = response_for
    records = normalize_rows(data.fetch(:accounts), warnings: warnings, kind: "account") { |raw| normalize_account(raw) }
    @inventory_ids = records.map { |record| record[:external_id] }
    @inventory_complete = warnings.empty?
    Provider::AccountData::Page.new(records: records, complete: @inventory_complete, mode: "snapshot",
      warnings: warnings, coverage: { "resource" => "account", "inventory" => "unwindowed" },
      evidence: { "response" => data.to_h })
  end

  def initial_history_start(account:, observed_at:)
    observed_at - 360.days
  end

  def checkpoint_history_start(account:, observed_at:, covered_through:)
    covered_through - 30.days
  end

  def initial_history_floor(account:, observed_at:)
    (observed_at.to_time.utc - 1.year).beginning_of_day
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    request = transaction_window(account, cursor: cursor, window: window)
    data, warnings = response_for(start_date: request[:start], end_date: request[:end])
    raw_account = response_account(data, account, warnings)
    rows = if raw_account
      if raw_account[:transactions].is_a?(Array)
        preferred_transactions(raw_account[:transactions], warnings)
      else
        warnings << warning("missing_transactions")
        []
      end
    else
      []
    end
    records = normalize_rows(rows, warnings: warnings, kind: "transaction") { |raw| normalize_transaction(raw, account: account) }
    next_cursor = if warnings.empty? && request[:start] > request[:requested_start]
      encode_cursor(account, request)
    end
    Provider::AccountData::Page.new(records: records, mode: "snapshot", warnings: warnings,
      complete: warnings.empty? && next_cursor.nil?, next_cursor: next_cursor,
      evidence: { "response" => data.to_h, "balance_policy_baseline" => balance_policy_snapshot(account) },
      coverage: {
        "resource" => "transaction", "start" => request[:requested_start].iso8601,
        "end" => request[:requested_end].iso8601, "page_start" => request[:start].iso8601,
        "page_end" => request[:end].iso8601, "pending_included" => include_pending,
        # SimpleFIN pending support varies by institution; absence is never proof
        # that an existing hold disappeared, even when pending=1 was requested.
        "pending_absence_authoritative" => false
      })
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise Provider::AccountData::InvalidResponse, "SimpleFIN holdings have no continuation cursor" unless cursor.nil?
    data, warnings = response_for
    raw_account = response_account(data, account, warnings, missing_is_empty: false)
    rows = raw_account&.fetch(:holdings, nil)
    unless rows.is_a?(Array)
      warnings << warning("missing_holdings")
      rows = []
    end
    records = normalize_rows(rows, warnings: warnings, kind: "holding") do |raw|
      normalize_holding(raw, account: account, institution: raw_account&.dig(:org))
    end
    Provider::AccountData::Page.new(records: records, complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      evidence: { "response" => data.to_h },
      coverage: { "resource" => "holding", "observed_date" => observed_date.to_s,
        "absence_authoritative" => false, "delete_future_holdings" => false })
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise Provider::AccountData::InvalidResponse, "SimpleFIN balance has no continuation cursor" unless cursor.nil?
    data, warnings = response_for
    raw = response_account(data, account, warnings, missing_is_empty: false)
    record = if raw
      normalize_account(raw)
    else
      Ingestion::Record.account(external_id: account[:external_id], name: account[:name], currency: account[:currency],
        metadata: { balance_provided: false, balance_policy: account[:metadata]&.dig(:balance_policy) || account[:metadata]&.dig("balance_policy") || {} })
    end
    input = (account[:metadata] || {}).with_indifferent_access[:simplefin_balance_input]
    snapshot = input ? input.fetch("snapshot") : balance_policy_snapshot(account)
    raise Provider::AccountData::InvalidResponse, "Missing captured SimpleFIN balance policy" unless snapshot.is_a?(Hash)
    evidence = { "response" => data.to_h, "balance_policy" => snapshot }
    evidence["balance_policy_input"] = input.except("snapshot").to_h if input
    Provider::AccountData::Page.new(records: [ record ], complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      coverage: { "resource" => "balance" }, evidence: evidence)
  end

  def balance_policy_snapshot(account)
    if @policy_snapshots[:version] == 2 || @policy_snapshots["version"] == 2
      inputs = @policy_snapshots.with_indifferent_access.fetch(:accounts)
      metadata = (account[:metadata] || {}).with_indifferent_access
      selected = inputs[metadata.fetch(:runtime_external_account_id)]
      unless selected && selected["identity_namespace"] == metadata.fetch(:runtime_identity_namespace)
        raise Provider::AccountData::InvalidResponse, "SimpleFIN balance policy belongs to another source account"
      end
      selected
    else
      # Explicit pure-adapter fixtures may supply the original unscoped shape.
      # RuntimeContext always uses the versioned UUID/namespace contract above.
      @policy_snapshots[account[:external_id]]
    end
  end

  def normalize_account(raw)
    data = raw.with_indifferent_access
    balance = optional_decimal(data[:balance])
    available = optional_decimal(data[:"available-balance"])
    raise ArgumentError if balance.nil? && available.nil?
    org = data[:org] || {}
    raise ArgumentError unless org.is_a?(Hash)
    holdings = data[:holdings]
    cash_balance = investment_cash(balance, holdings) if holdings.is_a?(Array)
    Ingestion::Record.account(
      external_id: identifier(data.fetch(:id)), name: data.fetch(:name),
      currency: account_currency(data[:currency]), account_type: data[:type].presence || "unknown",
      balance: balance, available_balance: available, cash_balance: cash_balance,
      balance_date: provider_date(data[:"balance-date"]),
      metadata: {
        institution: org, provider_account_subtype: data[:subtype],
        simplefin: { extra: data[:extra], closed: data[:closed], hidden: data[:hidden], holdings_present: holdings.is_a?(Array) },
        balance_policy: {
          observed_balance: "current_else_available", debt_transform: "absolute", debt_types: [ "Loan" ],
          cash_balance: "balance", investment_cash: "record", credit_card: "simplefin_overpayment_v1",
          available_credit: "positive_available_balance"
        }
      }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError, URI::InvalidURIError
    raise Provider::AccountData::InvalidResponse, "Invalid SimpleFIN account", cause: nil
  end

  def normalize_legacy_account(raw)
    data = legacy_monetary_values(raw, %w[balance available-balance])
    if data[:holdings].is_a?(Array)
      data[:holdings] = data[:holdings].map { |holding| legacy_monetary_values(holding, %w[market_value]) }
    end
    normalize_account(data)
  end

  def normalize_legacy_transaction(raw, account:)
    normalize_transaction(legacy_monetary_values(raw, %w[amount]), account: account)
  end

  def normalize_legacy_holding(raw, account:, institution: nil)
    normalize_holding(legacy_monetary_values(raw, %w[shares quantity qty units market_value current_value purchase_price price unit_price average_cost avg_cost cost_basis basis total_cost value]),
      account: account, institution: institution)
  end

  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    pending = pending?(data)
    return nil if pending && !include_pending
    tx_currency = known_currency(data[:currency])
    posted = provider_date(data[:posted])
    transacted = provider_date(data[:transacted_at])
    type = account[:account_type].to_s.strip.downcase.tr(" ", "_")
    date = %w[credit_card credit loan mortgage].include?(type) ? transacted || posted : posted || transacted
    raise ArgumentError unless date
    payee = data[:payee]&.strip
    extra = data.slice(:payee, :memo, :description).stringify_keys
    extra["extra"] = data[:extra] if data[:extra].is_a?(Hash)
    extra["pending"] = pending
    if tx_currency && tx_currency != account[:currency]
      extra["fx_from"] = tx_currency
      extra["fx_date"] = (transacted || posted)&.to_s
    end
    Ingestion::Record.transaction(
      external_id: "simplefin_#{identifier(data.fetch(:id))}", name: transaction_name(data),
      amount: -decimal(data.fetch(:amount)), currency: tx_currency || account[:currency],
      date: date, pending: pending,
      metadata: {
        extra: { "simplefin" => extra }, notes: transaction_notes(data),
        merchant: payee.present? ? { external_id: "simplefin_#{Digest::MD5.hexdigest(payee.downcase)}", name: payee } : nil,
        observation_order: transaction_preference(data), liability_policy_date: (posted || transacted)&.to_s
      }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid SimpleFIN transaction", cause: nil
  end

  def normalize_holding(raw, account:, institution: nil)
    data = raw.with_indifferent_access
    id = identifier(data.fetch(:id))
    description = data[:description].to_s.strip
    symbol = data[:symbol].presence
    if symbol.blank? && description.present?
      normalized = description.gsub(/[^a-zA-Z0-9]/, "_").upcase[0, 24]
      symbol = "CUSTOM:#{normalized}_#{Digest::MD5.hexdigest(description)[0, 5].upcase}"
    end
    raise ArgumentError unless symbol.is_a?(String) && symbol.present?
    symbol = symbol.upcase
    linked_type = (account[:metadata] || {}).with_indifferent_access[:linked_account_type] || account[:account_type]
    crypto = linked_type == "Crypto" || account[:name].to_s.downcase.include?("crypto") ||
      %w[BTC ETH SOL DOGE LTC BCH].include?(symbol) || description.downcase.include?("crypto")
    symbol = "CRYPTO:#{symbol}" if crypto && !symbol.include?(":")
    quantity = optional_decimal(first_value(data, %w[shares quantity qty units])) || BigDecimal("0")
    market = optional_decimal(first_value(data, %w[market_value current_value])) || BigDecimal("0")
    price = if quantity.positive? && market.positive?
      market / quantity
    else
      optional_decimal(first_value(data, %w[purchase_price price unit_price average_cost avg_cost])) || BigDecimal("0")
    end
    amount = market.positive? ? market : (quantity.positive? && price.positive? ? quantity * price : BigDecimal("0"))
    return nil if quantity.zero? && amount.zero?
    basis_key = %w[cost_basis basis total_cost value].find { |key| data[key].present? }
    basis = optional_decimal(data[basis_key]) if basis_key
    org = (institution || account[:metadata]&.dig(:institution) || account[:metadata]&.dig("institution") || {}).with_indifferent_access
    total_basis = TOTAL_BASIS_INSTITUTIONS.any? { |name| [ org[:name], org[:domain] ].compact.any? { |value| value.to_s.downcase.include?(name) } }
    if basis && (%w[total_cost value].include?(basis_key) || (total_basis && %w[cost_basis basis].include?(basis_key)))
      basis = quantity.positive? ? basis / quantity : nil
    end
    Ingestion::Record.holding(
      external_id: "simplefin_#{id}", quantity: quantity, amount: amount, price: price,
      currency: account_currency(data[:currency]), date: observed_date,
      security: { ticker: symbol, name: data[:description], offline: symbol.start_with?("CUSTOM:"), fallback_offline: true },
      metadata: { cost_basis: basis, cost_basis_source: basis_key, delete_future_holdings: false,
        cash_equivalent: cash_equivalent?(data) }
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError, URI::InvalidURIError
    raise Provider::AccountData::InvalidResponse, "Invalid SimpleFIN holding", cause: nil
  end

  private
    attr_reader :access_url, :include_pending, :observed_date

    def response_for(start_date: nil, end_date: nil)
      key = [ start_date&.iso8601, end_date&.iso8601, include_pending ]
      response = @responses.delete(key)
      unless response
        response = client.get_accounts_snapshot(access_url, start_date: start_date, end_date: end_date, pending: include_pending)
      end
      unless response.is_a?(Hash)
        raise Provider::AccountData::InvalidResponse, "Invalid SimpleFIN envelope"
      end
      data = response.with_indifferent_access
      unless data[:accounts].is_a?(Array) && (data[:errors].nil? || data[:errors].is_a?(Array))
        raise Provider::AccountData::InvalidResponse, "Invalid SimpleFIN envelope"
      end
      errors = Array(data[:errors]).dup
      errors << data[:error] if data[:error].present?
      if errors.any? && data[:accounts].empty?
        type = errors.any? { |error| error_category(error) == "rate_limited" } ? :rate_limited : :api_error
        raise Provider::Simplefin::SimplefinError.new("SimpleFIN did not return usable account data", type), cause: nil
      end
      @responses[key] = response
      @responses.shift while @responses.size > CACHE_SIZE
      [ data, errors.map { |error| warning(error_category(error)) } ]
    end

    def response_account(data, account, warnings, missing_is_empty: true)
      id = account[:external_id]
      matches = data.fetch(:accounts).select { |raw| raw.is_a?(Hash) && raw.with_indifferent_access[:id].to_s == id }
      raise Provider::AccountData::InvalidResponse, "Ambiguous SimpleFIN account identity" if matches.size > 1
      return matches.first.with_indifferent_access if matches.any?
      list_accounts if missing_is_empty && warnings.empty? && @inventory_complete.nil?
      unless missing_is_empty && warnings.empty? && @inventory_complete && @inventory_ids.include?(id)
        warnings << warning("missing_account")
      end
      nil
    end

    def normalize_rows(rows, warnings:, kind:)
      records = rows.filter_map do |row|
        yield row
      rescue Provider::AccountData::InvalidResponse
        warnings << warning("invalid_#{kind}")
        nil
      end
      duplicates = records.group_by { |record| record[:external_id] }.select { |_, values| values.size > 1 }
      unless duplicates.empty?
        warnings << warning("duplicate_#{kind}_identity")
        records.reject! { |record| duplicates.key?(record[:external_id]) }
      end
      records
    end

    def preferred_transactions(rows, warnings)
      selected = {}
      rows.each do |row|
        unless row.is_a?(Hash)
          warnings << warning("invalid_transaction")
          next
        end
        data = row.with_indifferent_access
        id = data[:id]
        unless id.is_a?(String) || id.is_a?(Integer)
          warnings << warning("invalid_transaction_identity")
          next
        end
        existing = selected[id.to_s]
        if existing.nil? || (transaction_preference(data) <=> transaction_preference(existing.with_indifferent_access)) == 1
          selected[id.to_s] = row
        end
      end
      selected.values
    end

    def transaction_preference(data)
      posted = data[:posted].respond_to?(:to_i) ? data[:posted].to_i : 0
      transacted = data[:transacted_at].respond_to?(:to_i) ? data[:transacted_at].to_i : 0
      [ posted.positive? ? 1 : 0, posted, data[:pending] ? 0 : 1, transacted ]
    end

    def pending?(data)
      return true if ActiveModel::Type::Boolean.new.cast(data[:pending])
      (data[:posted] == 0 || data[:posted] == "0") && data[:transacted_at].present? && data[:transacted_at].to_i.positive?
    end

    def transaction_name(data)
      payee = data[:payee]
      description = data[:description]
      if payee.present? && description.present? && payee != description
        "#{payee} - #{description}"
      else
        payee.presence || description.presence || data[:memo].presence || I18n.t("transactions.unknown_name")
      end
    end

    def transaction_notes(data)
      memo, payee, description = %i[memo payee description].map { |key| data[key].to_s.strip }
      parts = []
      parts << memo if memo.present?
      parts << "Payee: #{payee}" if payee.present? && payee != description
      parts.presence&.join(" | ")
    end

    def transaction_window(account, cursor:, window:)
      scope = (window || {}).with_indifferent_access
      requested_start = window_time(scope.fetch(:start))
      requested_end = window_time(scope.fetch(:end))
      raise ArgumentError unless requested_start < requested_end
      finish = requested_end
      if cursor
        raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 4096
        state = JSON.parse(Base64.strict_decode64(cursor))
        unless state == {
          "version" => 1, "account_id" => account[:external_id], "start" => requested_start.iso8601,
          "end" => requested_end.iso8601, "pending" => include_pending, "next_end" => state["next_end"]
        }
          raise ArgumentError
        end
        finish = window_time(state.fetch("next_end"))
        raise ArgumentError unless finish > requested_start && finish < requested_end
      end
      { requested_start: requested_start, requested_end: requested_end,
        start: [ requested_start, finish - WINDOW_SECONDS ].max, end: finish }
    rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError, JSON::ParserError
      raise Provider::AccountData::InvalidResponse, "Invalid SimpleFIN transaction window", cause: nil
    end

    def encode_cursor(account, request)
      Base64.strict_encode64(JSON.generate({
        version: 1, account_id: account[:external_id], start: request[:requested_start].iso8601,
        end: request[:requested_end].iso8601, pending: include_pending, next_end: request[:start].iso8601
      }))
    end

    def window_time(value)
      return value.to_time.utc if value.is_a?(Time) || value.is_a?(DateTime) || value.respond_to?(:in_time_zone) && !value.is_a?(String) && !value.instance_of?(Date)
      return value.to_time(:utc) if value.instance_of?(Date)
      raise ArgumentError unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(value).utc
    end

    def provider_date(value)
      if value.is_a?(BigDecimal)
        raise ArgumentError unless value.finite?
        return nil if value.to_i.zero?
        return Time.at(value).utc.to_date
      end
      ::Simplefin::DateUtils.parse_provider_date(value)
    end

    def decimal(value)
      raise ArgumentError unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(BigDecimal)
      parsed = BigDecimal(value.to_s)
      raise ArgumentError unless parsed.finite?
      parsed
    end

    def legacy_monetary_values(raw, fields)
      raise Provider::AccountData::InvalidResponse, "Invalid legacy SimpleFIN record" unless raw.is_a?(Hash)
      raw.deep_dup.with_indifferent_access.tap do |data|
        fields.each do |field|
          value = data[field]
          next unless value.is_a?(Float)
          raise Provider::AccountData::InvalidResponse, "Invalid legacy SimpleFIN number" unless value.finite?
          data[field] = BigDecimal(value.to_s)
        end
      end
    end

    def optional_decimal(value)
      value.nil? || value == "" ? nil : decimal(value)
    end

    def identifier(value)
      raise ArgumentError unless value.is_a?(String) || value.is_a?(Integer)
      raise ArgumentError if value.to_s.empty?
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

    def account_currency(value)
      value = "USD" if value.blank?
      value = URI.parse(value).path.split("/").last if value.is_a?(String) && value.start_with?("http")
      known_currency(value) || raise(ArgumentError)
    end

    def first_value(data, keys)
      keys.map { |key| data[key] }.find { |value| !value.nil? && !value.to_s.strip.empty? }
    end

    def investment_cash(balance, holdings)
      non_cash = holdings.sum(BigDecimal("0")) do |holding|
        raise ArgumentError unless holding.is_a?(Hash)
        data = holding.with_indifferent_access
        cash_equivalent?(data) ? BigDecimal("0") : (optional_decimal(data[:market_value]) || BigDecimal("0"))
      end
      (balance || BigDecimal("0")) - non_cash
    end

    def cash_equivalent?(data)
      @money_market_tickers.include?(data[:symbol].to_s.upcase.strip) ||
        @money_market_patterns.any? { |pattern| data[:description].to_s.match?(pattern) }
    end

    def warning(code)
      { "provider" => "simplefin", "code" => code, "scope" => "response" }
    end

    def error_category(error)
      message = if error.is_a?(Hash)
        error.with_indifferent_access.values_at(:code, :type, :description, :message, :error).compact.join(" ")
      else
        error.to_s
      end.downcase
      return "rate_limited" if message.match?(/429|rate limit|make fewer requests|only refreshed once every 24 hours/)
      return "institution_auth" if message.match?(/auth|forbidden|2fa|two-factor|token_expired/)
      return "institution_network" if message.match?(/timeout|timed out/)
      "institution_error"
    end
end
