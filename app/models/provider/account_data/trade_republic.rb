class Provider::AccountData::TradeRepublic < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include TimelineNormalization
  include TimelineGroups

  DEFINITION = Provider::AccountData::Definition.new(
    key: "trade_republic", source: "trade_republic", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "session_blob", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [], frozen: [], inventory: "linked" }
  end

  def self.context_sources
    [ :credential_store, :external_accounts, :trade_republic_retained_portfolio ]
  end

  def self.frozen_context_sources
    [ :trade_republic_retained_portfolio ]
  end

  def self.build(credentials:, settings:, context:)
    client = Provider::TradeRepublicClient::IngestionClient.new(credential_store: context.fetch(:credential_store))
    accounts = Array(context[:external_accounts])
    retained = RetainedPortfolio.adapter_inputs(snapshot: context.fetch(:trade_republic_retained_portfolio), external_accounts: accounts)
    linked_cash_ids = accounts.filter_map do |raw|
      row = raw.with_indifferent_access
      cash = retained.fetch(:topology).dig(row[:external_id], "kind") == "cash" || row[:external_id].to_s.start_with?("cash:")
      row[:external_id] if cash && row[:linked_account].present?
    end
    new(client: client, timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      currency: settings["currency"].presence || context.fetch(:family_currency), linked_cash_ids: linked_cash_ids,
      locale: context[:family_locale].presence || "en", **retained)
  end

  def initialize(client:, timezone:, observed_at:, currency: "EUR", linked_cash_ids: [], cached_positions: {}, locale: "en",
    topology: {}, cached_position_sources: {})
    super(client: client)
    @timezone, @observed_at, @currency = timezone, observed_at.to_time, normalized_currency(currency)
    @topology = Provider::AccountData::MigrationManifest.copy_value(topology)
    unless linked_cash_ids.is_a?(Array) && linked_cash_ids.all? { |id| id.is_a?(String) && (id.start_with?("cash:") || @topology.dig(id, "kind") == "cash") } &&
        cached_positions.is_a?(Hash) && cached_position_sources.is_a?(Hash)
      raise ArgumentError, "Invalid Trade Republic source snapshot"
    end
    @linked_cash_ids = linked_cash_ids.map { |id| id.dup.freeze }.freeze
    @labels = I18n.t("trade_republic_items.activities.labels", locale: locale).stringify_keys.freeze
    @institution_name = I18n.t("trade_republic_items.defaults.name", locale: locale)
    # Retained quote values come only from a verified frozen source archive.
    # Quantities, instruments and completeness still come from the live response.
    @cached_positions = cached_positions.deep_dup
    @cached_position_sources = cached_position_sources.deep_dup
  end

  def list_accounts(cursor: nil)
    raise ArgumentError unless cursor.nil?
    raw = client.get_account
    records = %w[portfolio cash].map { |kind| normalize_account(raw, kind: kind) }
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", evidence: { "response" => raw })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic inventory", cause: nil
  end

  def normalize_account(raw, kind:)
    raise ArgumentError unless %w[portfolio cash].include?(kind)
    data = normalized_object(raw)
    id = normalized_id(data.fetch(:securitiesAccountNumber))
    currency = normalized_currency(data[:currency].presence || @currency)
    external_id = local_account_id(owner: id, kind: kind)
    if @topology[external_id] && @topology[external_id].fetch("currency") != currency
      raise ArgumentError
    end
    Ingestion::Record.account(external_id: external_id, name: "#{@institution_name} #{kind.capitalize} (#{id})", currency: currency,
      account_type: kind == "cash" ? "Depository" : "Investment", sensitive_details: { securities_account_number: id },
      metadata: { kind: kind, balance_provided: false, institution: { name: "Trade Republic", domain: "traderepublic.com" },
        balance_policy: balance_policy })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic account", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    if cash_account?(account)
      response = normalized_object(client.get_cash)
      check_owner!(response.fetch(:account), account)
      # Legacy chooses available cash before cash, both as exact provider values.
      amount = money_amount(response[:available_cash]) || money_amount(response.fetch(:cash))
      raise ArgumentError if amount.nil?
      total = decimal(amount)
      evidence = { "response" => response }
      warnings = []
      cash = total
    else
      snapshot = portfolio_snapshot(account)
      values = snapshot.fetch(:positions).map do |position|
        next if position[:price].nil?
        decimal(position.fetch(:quantity)) * decimal(position.fetch(:price))
      end
      if snapshot.fetch(:missing_current_price) && !account[:balance].nil?
        total = account[:balance]
        fallback = true
      else
        total = values.compact.sum(BigDecimal("0"))
      end
      cash = BigDecimal("0")
      evidence = snapshot.fetch(:evidence).merge("fallback_balance" => fallback ? total : nil)
      warnings = snapshot.fetch(:warnings)
    end
    attrs = account.attributes.merge(balance: total, cash_balance: cash,
      metadata: (account[:metadata] || {}).with_indifferent_access.merge(balance_provided: true, balance_policy: balance_policy))
    Provider::AccountData::Page.new(records: [ Ingestion::Record.account(**attrs) ], complete: true, mode: "snapshot",
      warnings: warnings, evidence: evidence)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    return Provider::AccountData::Page.new(records: [], complete: true, mode: "delta") if cash_account?(account)
    snapshot = portfolio_snapshot(account)
    records = snapshot.fetch(:positions).filter_map { |position| normalize_holding(position, account: account) }
    if records.map { |record| record[:external_id] }.uniq.size != records.size
      raise ArgumentError
    end
    complete = snapshot.fetch(:warnings).empty? && records.size == snapshot.fetch(:positions).size
    # Current-day destructive reconciliation requires a shared, proven holding
    # scope. The old processor's LIKE-based deletion must not be copied here.
    Provider::AccountData::Page.new(records: records, complete: complete, mode: "snapshot",
      coverage: { "snapshot_date" => observation_date.iso8601, "absence_authoritative" => false },
      warnings: snapshot.fetch(:warnings), evidence: snapshot.fetch(:evidence))
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic holdings", cause: nil
  end

  def normalize_holding(raw, account:)
    raise ArgumentError if cash_account?(account)
    data = normalized_object(raw)
    isin = normalized_id(data.fetch(:isin))
    quantity = decimal(data.fetch(:quantity))
    return nil if quantity <= 0 || data[:price].nil?
    price = decimal(data.fetch(:price))
    date = observation_date
    Ingestion::Record.holding(external_id: "trade_republic_position_#{remote_account_id(account)}_#{isin}_#{date.iso8601}",
      date: date, currency: account[:currency], quantity: quantity, price: price, amount: quantity * price,
      security: security_descriptor(isin, data[:name]), metadata: { delete_future_holdings: false,
        cost_basis: data[:average_cost].nil? ? nil : decimal(data[:average_cost]), cost_basis_source: "provider" })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic holding", cause: nil
  end

  def normalize_legacy_holding(raw, account:)
    data = normalized_object(raw).deep_dup
    %i[quantity price average_cost].each { |key| data[key] = legacy_decimal(data[key]) if data.key?(key) }
    normalize_holding(data, account: account)
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    raise Provider::AccountData::UnsupportedCapability,
      "Trade Republic requires staged dual-topic timelines and an approved account partition"
  end

  def activity_scope
    :connection
  end

  def resumable_activity_groups?
    true
  end

  def activity_group_request_budget
    4
  end

  def activity_group_retry_delay(error:, attempt:)
    return unless error.is_a?(Provider::TradeRepublicClient::TransientProviderError) ||
      error.is_a?(Provider::TradeRepublicClient::Timeout) || error.is_a?(Provider::TradeRepublicClient::RateLimited)
    return unless attempt.is_a?(Integer) && attempt.between?(0, 4)

    delay = [ 15, 30, 60, 120, 240 ].fetch(attempt)
    if error.is_a?(Provider::TradeRepublicClient::RateLimited) && !error.retry_after.nil?
      return unless error.retry_after.is_a?(Numeric) && error.retry_after.finite? && error.retry_after.positive? && error.retry_after <= 300
      delay = [ delay, error.retry_after.ceil ].max
    end
    delay
  end

  private
    def portfolio_snapshot(account)
      response = normalized_object(client.get_portfolio)
      check_owner!(response.fetch(:account), account)
      portfolio = normalized_object(response.fetch(:portfolio))
      categories = checked_rows(portfolio.fetch(:categories))
      raw_positions = categories.flat_map do |category|
        checked_rows(category.fetch(:positions)).map { |position| position.merge(categoryType: category[:categoryType]) }
      end
      raise ArgumentError if raw_positions.size > Provider::TradeRepublicClient::IngestionClient::MAX_ROWS
      quotes, warnings = {}, []
      missing_current_price = false
      previous = Array(@cached_positions[account[:external_id]]).map { |value| normalized_object(value) }
        .to_h { |value| [ value.fetch(:isin).to_s, value[:price] ] }
      positions = raw_positions.map do |raw|
        isin = normalized_id(raw[:instrumentId].presence || raw.fetch(:isin))
        quantity = decimal(raw[:netSize] || raw.fetch(:quantity))
        quote = quotes[isin] ||= normalized_object(client.get_price(instrument_id: isin, category_type: raw[:categoryType]))
        check_owner!(quote.fetch(:account), account)
        price = quote[:price].nil? ? nil : decimal(quote[:price])
        if price.nil?
          missing_current_price = true
          warnings << { "code" => "position_price_unavailable" }
          price = decimal(previous[isin]) unless previous[isin].nil?
        end
        { isin: isin, name: raw[:name], quantity: quantity, price: price,
          average_cost: raw[:averageBuyIn] || raw[:avgCost], category: Provider::TradeRepublicClient::PORTFOLIO_CATEGORIES[raw[:categoryType]] || raw[:categoryType] }
      end
      { positions: positions, missing_current_price: missing_current_price, warnings: warnings, evidence: { "response" => response, "quotes" => quotes,
        "cached_prices" => previous.slice(*positions.select { |value| quotes[value[:isin]][:price].nil? }.map { |value| value[:isin] }),
        "cached_price_source" => @cached_position_sources[account[:external_id]] } }
    end

    def checked_rows(value)
      raise ArgumentError unless value.is_a?(Array) && value.size <= Provider::TradeRepublicClient::IngestionClient::MAX_ROWS
      value.map { |row| normalized_object(row) }
    end

    def cash_account?(account)
      @topology.dig(account[:external_id], "kind") == "cash" || account[:external_id].start_with?("cash:")
    end

    def local_account_id(owner:, kind:)
      retained = @topology.find { |_id, value| value.fetch("kind") == kind }
      if retained
        raise ArgumentError unless retained.last.fetch("owner_id") == owner
        retained.first
      else
        # Another retained kind can disprove this session, but never supplies an
        # alias for a source row that was not copied.
        raise ArgumentError if @topology.values.any? { |value| value.fetch("owner_id") != owner }
        kind == "cash" ? "cash:#{owner}" : owner
      end
    end

    def remote_account_id(account)
      retained = @topology[account[:external_id]]
      if retained
        metadata = account[:metadata] || {}
        supplied_id = metadata.with_indifferent_access[:runtime_external_account_id]
        raise ArgumentError if supplied_id && supplied_id != retained.fetch("external_account_id")
        retained.fetch("remote_id")
      else
        account[:external_id]
      end
    end

    def linked_cash_for?(account)
      owner = remote_account_id(account).delete_prefix("cash:")
      @linked_cash_ids.include?(local_account_id(owner: owner, kind: "cash"))
    end

    def check_owner!(raw, account)
      data = normalized_object(raw)
      id = normalized_id(data.fetch(:securitiesAccountNumber))
      expected = cash_account?(account) ? "cash:#{id}" : id
      raise ArgumentError unless remote_account_id(account) == expected
      reported = data[:currency].presence
      raise ArgumentError if reported && normalized_currency(reported) != account[:currency]
    end

    def observation_date
      @observed_at.in_time_zone(@timezone).to_date
    end

    def balance_policy
      { debt_transform: "preserve", debt_types: [], current_anchor: true }
    end

    def security_descriptor(isin, name)
      { ticker: isin, name: name.presence || isin, lookup: "ticker_only" }
    end

    def money_amount(value)
      case value
      when Hash
        direct = value["amount"] || value[:amount] || value["value"] || value[:value] ||
          value["balance"] || value[:balance] || value["available"] || value[:available]
        return direct if direct.is_a?(String) || direct.is_a?(Numeric)
        value.each_value do |child|
          amount = money_amount(child)
          return amount unless amount.nil?
        end
      when Array
        value.each do |child|
          amount = money_amount(child)
          return amount unless amount.nil?
        end
      end
      nil
    end

    def legacy_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end
end
