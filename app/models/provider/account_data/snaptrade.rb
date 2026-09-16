require "base64"
require "digest"
require "json"

class Provider::AccountData::Snaptrade < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include DataNormalization

  MAX_INVENTORY = 10_000
  PAGE_SIZE = Provider::Snaptrade::IngestionClient::PAGE_SIZE
  HISTORY_PAGES_PER_RUN = 20
  UNSUPPORTED_INSTRUMENTS = %w[option future cfd].freeze
  DEFINITION = Provider::AccountData::Definition.new(
    key: "snaptrade", source: "snaptrade", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "oauth_access_token", type: "string", secret: true },
      { name: "oauth_refresh_token", type: "string", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [ "currency" ], frozen: [], inventory: "linked" }
  end

  def self.context_sources
    %i[connection_details external_accounts authorizations application_credentials credential_store]
  end

  def self.build(credentials:, settings:, context:)
    application = context.fetch(:application_credentials).with_indifferent_access
    new(client: Provider::Snaptrade::IngestionClient.new(credential_store: context.fetch(:credential_store),
      oauth_client_id: application.fetch(:oauth_client_id), oauth_client_secret: application[:oauth_client_secret]),
      timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      connection_id: context.fetch(:connection_details).fetch(:id),
      external_accounts: context.fetch(:external_accounts), authorizations: context.fetch(:authorizations))
  end

  def initialize(client:, timezone:, observed_at:, connection_id:, external_accounts: [], authorizations: [])
    super(client: client)
    @timezone, @observed_at, @connection_id = timezone, observed_at.to_time, normalized_id(connection_id)
    @external_accounts = external_accounts.map { |row| normalized_object(row) }
    @authorizations = authorizations.map { |row| normalized_object(row) }
    @inventory, @snapshots, @history_requests = {}, {}, Hash.new(0)
  end

  def list_accounts(cursor: nil)
    raise ArgumentError unless cursor.nil?
    response = client.accounts_snapshot
    rows = bounded_array(response)
    warnings, authorization_response = [], nil
    begin
      authorization_response = client.authorizations_snapshot
      @authorization_inventory = bounded_array(authorization_response).map { |row| normalized_object(row) }
    rescue Provider::Snaptrade::Error, ArgumentError, KeyError, TypeError, NoMethodError
      warnings << warning("authorization_inventory_unavailable")
    end
    seen = {}
    records = rows.filter_map do |raw|
      record = normalize_account(raw)
      raise ArgumentError if seen[record[:external_id]]
      seen[record[:external_id]] = true
      @inventory[record[:external_id]] = normalized_object(raw)
      warnings << warning("brokerage_authorization_disabled", record[:external_id]) if record[:metadata][:authorization_disabled]
      record
    rescue Provider::AccountData::InvalidResponse, ArgumentError
      warnings << warning("invalid_account")
      nil
    end
    Provider::AccountData::Page.new(records: records, complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      evidence: { "accounts" => response, "authorizations" => authorization_response },
      coverage: { "resource" => "account", "absence_authoritative" => false })
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade account inventory", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    identity = normalized_id(data[:id])
    previous = @external_accounts.find { |row| row[:external_id] == identity }
    meta = normalized_object(data[:meta] || {})
    total = normalized_object(data.dig(:balance, :total) || {})
    institution = data[:institution_name] || meta[:institution_name]
    authorization_external_id = data[:brokerage_authorization]
    authorization_external_id = authorization_external_id[:id] if authorization_external_id.is_a?(Hash)
    authorization = @authorizations.find { |row| row[:external_id] == authorization_external_id } if authorization_external_id.present?
    upstream_authorization = Array(@authorization_inventory).find { |row| row[:id] == authorization_external_id }
    metadata = { balance_provided: false, provider_authorization_external_id: authorization_external_id,
      institution: { name: institution }.compact, account_status: data[:status],
      suggested_account_type: suggested_type(data, meta),
      authorization_disabled: upstream_authorization && upstream_authorization[:disabled] == true,
      first_transaction_date: parsed_date(data.dig(:sync_status, :transactions, :first_transaction_date))&.iso8601 }.compact
    metadata[:authorization_id] = authorization[:id] if authorization
    Ingestion::Record.account(external_id: identity, name: data[:name] || "#{institution} Account",
      currency: currency_code(total[:currency], fallback: previous&.dig(:currency)),
      account_type: meta[:type] || data[:raw_type], metadata: metadata,
      sensitive_details: { account_number: data[:number], snaptrade_account_snapshot: data,
        snaptrade_inventory_observed_at: @observed_at.iso8601(9) }.compact)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade account", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    state = account_snapshot(account)
    warnings = state.fetch(:warnings).dup
    record = begin
      warnings.empty? ? normalize_balance(state, account: account) : balance_record(account, state: state)
    rescue ArgumentError, KeyError, TypeError, NoMethodError
      warnings << warning("balance_denominations_or_components_incomplete", account[:external_id])
      balance_record(account, state: state)
    end
    Provider::AccountData::Page.new(records: [ record ], complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      evidence: state.fetch(:evidence), coverage: { "resource" => "balance", "end" => @observed_at.iso8601(9) })
  rescue ArgumentError, KeyError, TypeError, NoMethodError, Provider::AccountData::InvalidResponse
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade balance response", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    state = account_snapshot(account)
    warnings = state.fetch(:warnings).dup
    records = Array(state[:positions]).filter_map do |raw|
      normalize_holding(raw, account: account)
    rescue Provider::AccountData::InvalidResponse
      warnings << warning("invalid_holding", account[:external_id])
      nil
    end
    if state[:positions] && state[:balances]
      begin
        primary = primary_cash(state.fetch(:balances), account[:currency])
        primary_currency = currency_code(primary&.dig(:currency))
        state.fetch(:balances).each do |raw|
          cash = normalized_object(raw)
          code = currency_code(cash[:currency])
          next if code.nil? || code == primary_currency || cash[:cash].blank?
          amount = decimal(cash[:cash]) - cash_equivalent_value(state.fetch(:positions), code, account[:currency])
          records << Ingestion::Record.holding(external_id: "snaptrade_cash_#{code.downcase}", currency: code,
            date: observed_date, quantity: amount, price: BigDecimal("1"), amount: amount,
            security: { lookup: "account_cash", currency: code }, metadata: { delete_future_holdings: false })
        end
      rescue ArgumentError, TypeError, NoMethodError
        warnings << warning("invalid_cash_holdings", account[:external_id])
      end
    end
    Provider::AccountData::Page.new(records: records, complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      evidence: state.fetch(:evidence), coverage: { "resource" => "holding", "end" => @observed_at.iso8601(9), "absence_authoritative" => false })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade holdings response", cause: nil
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    identity = normalized_id(account[:external_id])
    if @history_requests[identity] >= HISTORY_PAGES_PER_RUN
      raise Provider::AccountData::IncompletePage, "SnapTrade history request budget exhausted; saved progress can resume"
    end
    state = history_state(account, cursor, window)
    @history_requests[identity] += 1
    response = client.activities_page(account_id: identity, start_date: state.fetch("start"), end_date: state.fetch("end"), offset: state.fetch("offset"))
    rows, total = activity_rows(response, offset: state.fetch("offset"))
    warnings = []
    warnings << warning("history_count_changed", identity) if state["total"] && state["total"] != total
    consumed = state.fetch("offset") + rows.size
    warnings << warning("incomplete_history_page", identity) if consumed > total || (rows.size < PAGE_SIZE && consumed < total)
    evidence = { "response" => response }

    # Preserve the old cross-account fallback for sparse, long histories before
    # exposing any first-page records. It cannot erase already imported history.
    if state["offset"].zero? && consumed == total && total < 10 && (Date.iso8601(state["end"]) - Date.iso8601(state["start"])) > 365
      begin
        fallback = client.activities_fallback_snapshot(account_id: identity, start_date: state.fetch("start"), end_date: state.fetch("end"))
        evidence["fallback_response"] = fallback
        fallback_rows = bounded_array(fallback, limit: 1000)
        # The legacy array response has no count or completeness marker. Retain
        # useful rows while refusing to advance coverage on an inferred end.
        warnings << warning("fallback_completeness_unknown", identity)
        if fallback_rows.size < 1000 && fallback_rows.size > rows.size
          rows = fallback_rows
        end
      rescue Provider::Snaptrade::Error, ArgumentError
        warnings << warning("activities_fallback_unavailable", identity)
      end
    end
    ids = rows.filter_map do |raw|
      normalized_id(normalized_object(raw)[:id])
    rescue ArgumentError
      nil # The row normalizer below records a diagnostic and retains evidence.
    end
    warnings << warning("repeated_history_rows", identity) if ids.uniq.size != ids.size || (ids & state.fetch("previous_ids")).any?
    records = rows.filter_map do |raw|
      normalize_activity(raw, account: account)
    rescue Provider::AccountData::InvalidResponse
      warnings << warning("invalid_activity", identity)
      nil
    end
    if rows.empty?
      # SnapTrade initial brokerage indexing is asynchronous. A legitimate empty
      # account and an unindexed connection need an explicit readiness signal.
      warnings << warning("empty_history_requires_readiness", identity)
    end
    complete = consumed == total && warnings.empty?
    continuation = if consumed < total && warnings.empty?
      encode_cursor(state.merge("offset" => consumed, "total" => total, "previous_ids" => ids))
    end
    Provider::AccountData::Page.new(records: records, complete: complete, mode: "delta", warnings: warnings,
      next_cursor: continuation, progress_cursor: continuation, evidence: evidence,
      coverage: { "resource" => "activity", "start" => state.fetch("start"), "end" => state.fetch("end"),
        "pending_absence_authoritative" => false, "date_basis" => "trade_date" })
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade activities response", cause: nil
  end

  private
    def account_snapshot(account)
      identity = normalized_id(account[:external_id])
      return @snapshots[identity] if @snapshots.key?(identity)
      if normalized_object(account[:metadata] || {})[:authorization_disabled] == true
        raise Provider::AccountData::IncompletePage, "SnapTrade brokerage authorization requires repair"
      end
      evidence, warnings = {}, []
      state = { evidence: evidence, warnings: warnings }
      { account: -> { @inventory[identity] || client.account_snapshot(account_id: identity) },
        balances: -> { client.balances_snapshot(account_id: identity) },
        positions: -> { client.positions_snapshot(account_id: identity) } }.each do |resource, read|
        begin
          evidence[resource.to_s] = response = read.call
          state[resource] = case resource
          when :account
            row = normalized_object(response)
            raise ArgumentError unless normalized_id(row[:id]) == identity
            row
          when :balances
            bounded_array(response).map { |row| normalized_object(row) }
          when :positions
            bounded_array(normalized_object(response).fetch(:results)).reject { |row| unsupported_holding?(row) }
          end
        rescue Provider::Snaptrade::Error, ArgumentError, KeyError, TypeError, NoMethodError
          warnings << warning("#{resource}_snapshot_unavailable", identity)
        end
      end
      @snapshots[identity] = state
    end

    def normalize_balance(state, account:)
      positions, balances = state.fetch(:positions), state.fetch(:balances)
      code = currency_code(state.fetch(:account).dig(:balance, :total, :currency), fallback: account[:currency])
      raise ArgumentError unless code
      primary = primary_cash(balances, code)
      # An omitted cash entry cannot safely reuse already-adjusted shared cash.
      raise ArgumentError unless primary && !primary[:cash].nil?
      primary_code = currency_code(primary[:currency], fallback: code)
      cash = decimal(primary[:cash]) - cash_equivalent_value(positions, primary_code, code)
      # The legacy processor can label fallback USD cash as account currency.
      # Preserve retained history, but quarantine new mismatched denominations.
      raise ArgumentError unless primary_code == code
      holdings = positions.sum(BigDecimal("0")) do |raw|
        row = normalized_object(raw)
        decimal(row.fetch(:units)) * decimal(row.fetch(:price))
      end
      total = state.fetch(:account).dig(:balance, :total, :amount)
      total = decimal(total) unless total.nil?
      foreign = positions.any? do |raw|
        row = normalized_object(raw)
        position_currency(row, code) != code
      end
      raise ArgumentError if foreign && total.nil?
      balance = if foreign && total
        total
      elsif holdings.positive?
        holdings + cash
      else
        total || holdings + cash
      end
      balance_record(account, state: state, code: code, balance: balance, cash: cash)
    end

    def balance_record(account, state:, code: account[:currency], balance: nil, cash: nil)
      metadata = normalized_object(account[:metadata] || {}).merge(balance_provided: !balance.nil?,
        balance_policy: { current_anchor: true, debt_transform: "preserve", cash_balance: "record" })
      details = normalized_object(account[:sensitive_details] || {}).merge(snaptrade_snapshot: {
        observed_at: @observed_at.iso8601(9), account: state[:account], balances: state[:balances], positions: state[:positions]
      })
      Ingestion::Record.account(external_id: account[:external_id], name: account[:name], currency: code,
        account_type: account[:account_type], balance: balance, cash_balance: cash,
        balance_date: balance && observed_date, sensitive_details: details, metadata: metadata)
    end

    def primary_cash(rows, code)
      rows.find { |row| currency_code(row[:currency]) == code } || rows.find { |row| currency_code(row[:currency]) == "USD" } || rows.first
    end

    def cash_equivalent_value(positions, code, fallback)
      positions.sum(BigDecimal("0")) do |raw|
        row = normalized_object(raw)
        next BigDecimal("0") unless row[:cash_equivalent] == true && position_currency(row, fallback) == code
        decimal(row.fetch(:units)) * decimal(row.fetch(:price))
      end
    end

    def activity_rows(response, offset:)
      if response.is_a?(Array)
        rows = bounded_array(response, limit: PAGE_SIZE)
        # A full bare array has no proof that the endpoint did not truncate it.
        raise ArgumentError unless rows.size < PAGE_SIZE
        return [ rows, offset + rows.size ]
      end
      data = normalized_object(response)
      rows = bounded_array(data.fetch(:data), limit: PAGE_SIZE)
      pagination = normalized_object(data.fetch(:pagination))
      total = pagination.fetch(:total)
      raise ArgumentError unless pagination[:offset] == offset && pagination[:limit] == PAGE_SIZE && total.is_a?(Integer) && total >= 0
      [ rows, total ]
    end

    def history_state(account, cursor, window)
      if cursor
        raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 131_072
        state = JSON.parse(Base64.strict_decode64(cursor))
        unless state.is_a?(Hash) && state.keys.sort == %w[account_id connection_id end offset previous_ids start total version] &&
            state["version"] == 1 && state["connection_id"] == @connection_id && state["account_id"] == account[:external_id] &&
            state["offset"].is_a?(Integer) && state["offset"].between?(0, 2_147_483_647) && state["total"].is_a?(Integer) &&
            state["total"] > state["offset"] && state["previous_ids"].is_a?(Array) && state["previous_ids"].size <= PAGE_SIZE &&
            state["previous_ids"].all? { |id| id.is_a?(String) && id.present? } &&
            Date.iso8601(state["start"]) <= Date.iso8601(state["end"]) && Date.iso8601(state["end"]) <= observed_date
          raise ArgumentError
        end
        return state
      end
      scope = normalized_object(window || {})
      metadata = normalized_object(account[:metadata] || {})
      # Full initial history follows the legacy first-transaction/three-year
      # fallback. Generic ninety-day defaults are not an initial history floor.
      first = scope[:explicit_start] ? parsed_date(scope.fetch(:start)) : parsed_date(metadata[:first_transaction_date])
      first ||= observed_date - 1095
      last = scope[:end] ? [ parsed_date(scope[:end]), observed_date ].min : observed_date
      raise ArgumentError if first > last
      { "version" => 1, "connection_id" => @connection_id, "account_id" => account[:external_id],
        "start" => first.iso8601, "end" => last.iso8601, "offset" => 0, "total" => nil, "previous_ids" => [] }
    end

    def encode_cursor(state)
      Base64.strict_encode64(JSON.generate(state))
    end

    def bounded_array(value, limit: MAX_INVENTORY)
      raise ArgumentError unless value.is_a?(Array) && value.size <= limit
      value
    end

    def warning(code, account_id = nil)
      { "code" => code, "provider_key" => "snaptrade", "external_account_id" => account_id }.compact
    end

    def observed_date
      @observed_at.in_time_zone(@timezone).to_date
    end
end
