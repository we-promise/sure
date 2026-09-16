require "base64"
require "json"

class Provider::AccountData::Ibkr < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  PAGE_SIZE = 100
  DEFINITION = Provider::AccountData::Definition.new(
    key: "ibkr", source: "ibkr", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "query_id", type: "string", secret: true }, { name: "token", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.frozen_context_sources
    [ :ibkr_export ]
  end

  def self.context_sources
    [ :ibkr_export ]
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    archive = context.fetch(:ibkr_export)
    new(client: Provider::IbkrFlex.new(query_id: credentials.fetch(:query_id), token: credentials.fetch(:token)),
      timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at), now: context.fetch(:current_time),
      export_scope: archive.fetch(:scope), staged_export: archive.fetch(:export))
  end

  # staged_xml is an explicit immutable archive input, never read from old models.
  # The runtime must supply the matching snapshot when a slice resumes later.
  def initialize(client:, timezone:, observed_at:, staged_xml: nil, export_scope: nil, staged_export: nil, now: nil)
    super(client: client)
    @timezone = timezone
    @observed_at = observed_at.to_time
    @now = (now || observed_at).to_time
    @export_scope = export_scope
    if export_scope
      Export.validate_scope!(export_scope)
      raise ArgumentError unless export_scope["observed_at"] == @observed_at.utc.iso8601(9) && export_scope["timezone"] == timezone
      @export_scope = Provider::AccountData::MigrationManifest.copy_value(export_scope)
    end
    raise ArgumentError if staged_xml && staged_export
    if staged_export
      raise ArgumentError unless @export_scope
      @export = Export.load(staged_export, expected_scope: @export_scope)
      @statement = @export.statement
    elsif staged_xml
      install_statement!(staged_xml)
    end
  end

  def list_accounts(cursor: nil)
    state = cursor ? decode_cursor(cursor, resource: "inventory") : nil
    # A saved ready page may already have archived the export before a crash.
    # Replaying its earlier poll cursor must not ask IBKR for another response.
    state = nil if @statement && state && state["phase"] == "poll"
    if state && state["phase"] == "poll"
      return pending_page(state, evidence: {}) if @now < Time.iso8601(state.fetch("available_at"))
      if state.fetch("attempts") >= Provider::IbkrFlex::MAX_POLL_ATTEMPTS
        raise Provider::AccountData::IncompletePage, "IBKR Flex poll budget exhausted; the statement needs a later reviewed retry"
      end
      result = client.poll_statement_page(reference: state.fetch("reference"))
      validate_poll_result!(result, reference: state.fetch("reference"))
      if result[:status] == "pending"
        return pending_page(state.merge("attempts" => state.fetch("attempts") + 1,
          "available_at" => (@now + Provider::IbkrFlex::POLL_INTERVAL).iso8601(9)), evidence: result.fetch(:evidence))
      end
      install_statement!(result.fetch(:xml))
      state = nil
    elsif !state && !@statement
      result = client.request_statement_page
      unless result.is_a?(Hash) && result[:status] == "requested" && valid_reference?(result[:reference]) && result[:evidence].is_a?(Hash)
        raise ArgumentError
      end
      return pending_page(scoped_cursor({ "resource" => "inventory", "phase" => "poll", "reference" => result[:reference],
        "attempts" => 0, "available_at" => (@now + Provider::IbkrFlex::POLL_INTERVAL).iso8601(9) }), evidence: result[:evidence])
    end
    statement = statement_for!(state)
    offset = state ? state.fetch("offset") : 0
    accounts = statement.accounts
    rows = accounts.slice(offset, PAGE_SIZE)
    raise ArgumentError if rows.nil?
    next_offset = offset + rows.size
    continuation = next_offset < accounts.size ? slice_cursor("inventory", next_offset) : nil
    Provider::AccountData::Page.new(records: rows.map { |data| normalize_account(data) }, complete: continuation.nil?, mode: "snapshot",
      next_cursor: continuation, progress_cursor: continuation,
      evidence: @export ? { "ibkr_export" => offset.zero? ? @export.payload : @export.reference } :
        { "statement_sha256" => statement.fingerprint, "response_xml" => statement.xml })
  rescue ArgumentError, TypeError, KeyError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid IBKR account inventory", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    data = statement_account!(account)
    Provider::AccountData::Page.new(records: [ normalize_account(data) ], complete: true, mode: "snapshot",
      coverage: statement_coverage(data), evidence: section_evidence(data, %w[position_values cash_report]))
  rescue ArgumentError, TypeError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid IBKR balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    data = statement_account!(account)
    state = cursor ? decode_cursor(cursor, resource: "holdings", account: account[:external_id]) : nil
    statement_for!(state)
    require_section!(data, "open_positions")
    # All tax lots of a conid/date/currency must be in one normalized record.
    groups = data.fetch("open_positions").select { |row| supported_position?(row) }.group_by do |row|
      [ required(row, "conid"), flex_date(required(row, "report_date")), normalized_currency(required(row, "currency")) ]
    end.values
    offset = state ? state.fetch("offset") : 0
    rows = groups.slice(offset, PAGE_SIZE)
    raise ArgumentError if rows.nil?
    continuation = offset + rows.size < groups.size ? slice_cursor("holdings", offset + rows.size, account: account[:external_id]) : nil
    records = rows.filter_map { |lots| normalize_holding(lots, account: account) }
    Provider::AccountData::Page.new(records: records, complete: continuation.nil?, mode: "snapshot",
      next_cursor: continuation, progress_cursor: continuation, coverage: statement_coverage(data).merge("absence_authoritative" => false),
      evidence: section_evidence(data, %w[open_positions], rows: rows.flatten))
  rescue ArgumentError, TypeError, KeyError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid IBKR holdings", cause: nil
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    data = statement_account!(account)
    state = cursor ? decode_cursor(cursor, resource: "activities", account: account[:external_id]) : nil
    # A completed checkpoint is evidence of a prior export, not an offset into
    # a freshly requested export. Every new statement is read in full by identity.
    state = nil if state && state["phase"] == "checkpoint"
    statement_for!(state)
    require_section!(data, "trades")
    require_section!(data, "cash_transactions")
    phase = state ? state.fetch("phase") : "trades"
    offset = state ? state.fetch("offset") : 0
    rows = data.fetch(phase).slice(offset, PAGE_SIZE)
    raise ArgumentError if rows.nil?
    records = rows.flat_map do |row|
      phase == "trades" ? normalize_trade(row, account: account) : [ normalize_cash(row, account: account, data: data) ].compact
    end
    next_phase, next_offset = if offset + rows.size < data.fetch(phase).size
      [ phase, offset + rows.size ]
    elsif phase == "trades"
      [ "cash_transactions", 0 ]
    end
    continuation = next_phase ? slice_cursor("activities", next_offset, account: account[:external_id], phase: next_phase) : nil
    Provider::AccountData::Page.new(records: records, complete: continuation.nil?, mode: "delta",
      next_cursor: continuation, progress_cursor: continuation,
      checkpoint_cursor: continuation ? nil : slice_cursor("activities", 0, account: account[:external_id], phase: "checkpoint"),
      coverage: statement_coverage(data), evidence: section_evidence(data, [ phase ], rows: rows))
  rescue ArgumentError, TypeError, KeyError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid IBKR activity page", cause: nil
  end

  # Auxiliary input for an explicit post-materialization operation. This is not
  # an account balance page: the shared writer must preserve calculated cash.
  def historical_equity(account:)
    data = statement_account!(account)
    require_section!(data, "equity_summary")
    { rows: data.fetch("equity_summary"), currency: data.fetch("currency"),
      statement_sha256: @statement.fingerprint, evidence: section_evidence(data, %w[equity_summary]) }
  end

  def normalize_account(data)
    currency = normalized_currency(data.fetch("currency"))
    cash = summary_amount(data.fetch("cash_report"), "ending_cash", currency)
    positions = summary_amount(data.fetch("position_values"), "end_of_period_value", currency)
    Ingestion::Record.account(external_id: data.fetch("external_id"), name: data.fetch("external_id"), currency: currency,
      account_type: "Investment", balance: positions + cash, cash_balance: cash, balance_date: flex_date(data.fetch("report_date")),
      metadata: { institution: { name: "Interactive Brokers", domain: "interactivebrokers.com" },
        statement_sha256: @statement&.fingerprint, statement_sync_id: @export_scope&.fetch("sync_id"),
        statement_observed_on: @export_scope&.fetch("observed_on"), statement_from_date: data.fetch("from_date"), statement_to_date: data.fetch("to_date"),
        balance_policy: { current_anchor: true, cash_balance: "cash_balance" } })
  end

  def normalize_holding(lots, account:)
    sample = lots.first
    currency = normalized_currency(required(sample, "currency"))
    date = flex_date(required(sample, "report_date"))
    security = security_descriptor(required(sample, "symbol"))
    price = flex_decimal(required(sample, "mark_price"))
    raise ArgumentError if price.negative?
    quantity = BigDecimal("0")
    cost = BigDecimal("0")
    lots.each do |row|
      %w[security_id security_id_type fx_rate_to_base].each { |field| required(row, field) }
      unless security_descriptor(required(row, "symbol")) == security && flex_decimal(required(row, "mark_price")) == price &&
          normalized_currency(required(row, "currency")) == currency && flex_date(required(row, "report_date")) == date
        raise ArgumentError
      end
      fx = flex_decimal(row.fetch("fx_rate_to_base"))
      raise ArgumentError unless fx.positive?
      qty = flex_decimal(required(row, "position")).abs
      basis = flex_decimal(required(row, "cost_basis_price"))
      quantity += qty
      cost += qty * basis
    end
    return nil if quantity.zero?
    Ingestion::Record.holding(external_id: [ "ibkr", account[:external_id], required(sample, "conid"), date.iso8601, currency ].join("_"),
      security: security, date: date, currency: currency, quantity: quantity, price: price, amount: quantity * price,
      metadata: { cost_basis: cost / quantity, delete_future_holdings: false, conid: sample.fetch("conid"),
        security_id: sample.fetch("security_id"), security_id_type: sample.fetch("security_id_type") })
  end

  def normalize_trade(row, account:)
    return [] unless row["asset_category"] == "STK"
    %w[conid currency quantity symbol trade_date trade_id trade_price transaction_id buy_sell].each { |key| required(row, key) }
    side = row.fetch("buy_sell").upcase
    raise ArgumentError unless %w[BUY SELL].include?(side)
    quantity = flex_decimal(row.fetch("quantity")).abs
    price = flex_decimal(row.fetch("trade_price"))
    raise ArgumentError if price.negative?
    currency = normalized_currency(row.fetch("currency"))
    rate = exchange_rate(row, account: account)
    date = flex_date(row.fetch("trade_date"))
    security = security_descriptor(row.fetch("symbol"))
    label = side == "SELL" ? "Sell" : "Buy"
    signed_quantity = side == "SELL" ? -quantity : quantity
    record = Ingestion::Record.activity(external_id: "ibkr_trade_#{row.fetch('trade_id')}", activity_type: side.downcase, ledger_type: "trade",
      security: security, quantity: signed_quantity, price: price, amount: side == "SELL" ? -(price * quantity) : price * quantity,
      currency: currency, date: date, name: "#{label} #{quantity} shares of #{security[:ticker]}",
      metadata: { investment_activity_label: label, exchange_rate: rate, allow_zero_quantity: quantity.zero? })
    commission = optional_decimal(row["ib_commission"])
    return [ record ] if commission.nil? || commission.zero?
    fee_currency = normalized_currency(row["ib_commission_currency"].presence || account[:currency])
    fee = Ingestion::Record.activity(external_id: "ibkr_trade_fee_#{row.fetch('trade_id')}", activity_type: "fee", ledger_type: "transaction",
      security: security, amount: commission.abs, currency: fee_currency, date: date, name: "Trade Commission for #{security[:ticker]}",
      metadata: { investment_activity_label: "Fee", extra: { exchange_rate: rate, ibkr: row.slice("trade_id", "transaction_id",
        "ib_commission", "ib_commission_currency", "fx_rate_to_base") } })
    [ record, fee ]
  end

  def normalize_cash(row, account:, data:)
    type = row["type"].to_s.upcase.strip
    return nil unless [ "DEPOSITS/WITHDRAWALS", "DIVIDENDS" ].include?(type)
    %w[transaction_id amount currency report_date].each { |key| required(row, key) }
    required(row, "conid") if type == "DIVIDENDS"
    amount = flex_decimal(row.fetch("amount"))
    return nil if amount.zero?
    rate = exchange_rate(row, account: account)
    kind, label, signed = if type == "DIVIDENDS"
      [ "dividend", "Dividend", -amount.abs ]
    elsif amount.positive?
      [ "contribution", "Contribution", -amount.abs ]
    else
      [ "withdrawal", "Withdrawal", amount.abs ]
    end
    symbol = (data.fetch("open_positions") + data.fetch("trades")).find { |item| row["conid"].present? && item["conid"] == row["conid"] }&.fetch("symbol", nil)
    security = symbol.present? ? security_descriptor(symbol) : nil
    attrs = { external_id: "ibkr_cash_#{row.fetch('transaction_id')}", activity_type: kind, ledger_type: "transaction", amount: signed,
      currency: normalized_currency(row.fetch("currency")), date: flex_date(row.fetch("report_date")),
      name: kind == "dividend" ? "Dividend from #{security ? security[:ticker] : row.fetch('conid')}" : label,
      metadata: { investment_activity_label: label, extra: { exchange_rate: rate, ibkr: row.slice("transaction_id", "type", "conid",
        "amount", "currency", "fx_rate_to_base", "report_date") } } }
    attrs[:security] = security if security
    Ingestion::Record.activity(**attrs)
  end

  private
    def install_statement!(xml)
      if @export_scope
        @export = Export.new(xml: xml, scope: @export_scope)
        @statement = @export.statement
      else
        @statement = Statement.new(xml, observed_on: observation_date)
      end
    end

    def observation_date
      @observed_at.in_time_zone(@timezone).to_date
    end

    def flex_decimal(value)
      Values.decimal(value)
    end

    def optional_decimal(value)
      value.nil? || value == "" || value == "-" ? nil : flex_decimal(value)
    end

    def flex_date(value)
      Values.date(value)
    end

    def required(row, key)
      value = row.fetch(key)
      raise ArgumentError unless value.is_a?(String) && value.present?
      value
    end

    def exchange_rate(row, account:)
      rate = optional_decimal(row["fx_rate_to_base"])
      raise ArgumentError if rate && !rate.positive?
      if normalized_currency(row.fetch("currency")) != account[:currency] && rate.nil?
        raise Provider::AccountData::IncompletePage, "IBKR foreign currency activity is missing its rate to base"
      end
      rate
    end

    def security_descriptor(symbol)
      ticker = normalized_id(symbol).strip.upcase
      raise ArgumentError if ticker.blank?
      { ticker: ticker, name: ticker, lookup: "ticker_only" }
    end

    def summary_amount(rows, field, currency)
      matches = rows.select { |row| row["currency"] == "BASE_SUMMARY" }
      matches = rows.select { |row| row["currency"] == currency } if matches.empty?
      unless matches.one?
        raise Provider::AccountData::IncompletePage, "IBKR statement is missing an unambiguous base balance"
      end
      flex_decimal(required(matches.first, field))
    end

    def supported_position?(row)
      row["asset_category"] == "STK" && row["side"] == "Long"
    end

    def require_section!(data, section)
      unless data.fetch("sections").include?(section)
        raise Provider::AccountData::IncompletePage, "IBKR Flex query omitted a required section"
      end
    end

    def statement_for!(state = nil)
      unless @statement && (!state || state.fetch("fingerprint") == @statement.fingerprint)
        raise Provider::AccountData::IncompletePage, "The original IBKR statement snapshot is required to resume this page"
      end
      @statement
    end

    def statement_account!(account)
      statement = statement_for!
      fingerprint = (account[:metadata] || {}).with_indifferent_access[:statement_sha256]
      metadata = (account[:metadata] || {}).with_indifferent_access
      if fingerprint != statement.fingerprint || (@export_scope && (metadata[:statement_sync_id] != @export_scope.fetch("sync_id") ||
          metadata[:statement_observed_on] != @export_scope.fetch("observed_on")))
        raise Provider::AccountData::IncompletePage, "IBKR account belongs to a different statement snapshot"
      end
      statement.accounts.find { |item| item.fetch("external_id") == account[:external_id] } || raise(ArgumentError)
    end

    def statement_coverage(data)
      { "start" => data.fetch("from_date"), "end" => data.fetch("to_date"), "scope" => "configured_flex_query",
        "statement_sha256" => @statement.fingerprint }
    end

    def section_evidence(data, sections, rows: nil)
      payload = sections.to_h { |section| [ section, data.fetch(section) ] }
      payload = { "sections" => sections, "rows" => rows } unless rows.nil?
      { "statement_sha256" => @statement.fingerprint, "export_scope" => @export_scope, "account_id" => data.fetch("external_id"), "response" => payload }
    end

    def pending_page(state, evidence:)
      Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
        progress_cursor: Base64.urlsafe_encode64(JSON.generate(state), padding: false),
        coverage: { "available_at" => state.fetch("available_at") }, warnings: [ { "code" => "statement_pending" } ], evidence: evidence)
    end

    def valid_reference?(reference)
      reference.is_a?(String) && reference.match?(/\A[A-Za-z0-9_-]{1,256}\z/)
    end

    def validate_poll_result!(result, reference:)
      unless result.is_a?(Hash) && %w[pending ready].include?(result[:status]) && result[:reference] == reference && result[:evidence].is_a?(Hash)
        raise ArgumentError
      end
    end

    def slice_cursor(resource, offset, account: nil, phase: "rows")
      state = scoped_cursor({ "resource" => resource, "phase" => phase, "offset" => offset, "fingerprint" => @statement.fingerprint, "account" => account })
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def scoped_cursor(state)
      @export_scope ? state.merge("version" => 2, "scope" => @export_scope) : state.merge("version" => 1)
    end

    def decode_cursor(cursor, resource:, account: nil)
      raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 4096
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      raise ArgumentError unless state.is_a?(Hash) && state["version"] == (@export_scope ? 2 : 1) && state["resource"] == resource
      if @export_scope
        Export.validate_scope!(state["scope"])
        if resource == "activities" && state["phase"] == "checkpoint"
          # A completed checkpoint starts the next export from its first row.
          unless state["scope"].slice("family_id", "provider_connection_id") == @export_scope.slice("family_id", "provider_connection_id") &&
              Time.iso8601(state["scope"].fetch("observed_at")) <= @observed_at
            raise ArgumentError
          end
        else
          raise ArgumentError unless state["scope"] == @export_scope
        end
      end
      keys = state.keys - (@export_scope ? [ "scope" ] : [])
      if state["phase"] == "poll"
        unless resource == "inventory" && keys.sort == %w[attempts available_at phase reference resource version] && valid_reference?(state["reference"]) &&
            state["attempts"].is_a?(Integer) && state["attempts"].between?(0, Provider::IbkrFlex::MAX_POLL_ATTEMPTS) && state["available_at"].is_a?(String)
          raise ArgumentError
        end
        Time.iso8601(state["available_at"])
      else
        phases = resource == "activities" ? %w[trades cash_transactions checkpoint] : [ "rows" ]
        unless keys.sort == %w[account fingerprint offset phase resource version] && phases.include?(state["phase"]) && state["account"] == account &&
            state["offset"].is_a?(Integer) && state["offset"] >= 0 && state["fingerprint"].is_a?(String) && state["fingerprint"].match?(/\A[0-9a-f]{64}\z/)
          raise ArgumentError
        end
      end
      state
    end
end
