require "base64"
require "digest/sha2"
require "json"

# Redbark's API credential spans upstream connections. Banking and document
# connections expose transactions; its brokerage/trades product is separate.
class Provider::AccountData::Redbark < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "redbark", source: "redbark", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "api_key", type: "text", secret: true } ]
  )
  MAX_PAGES = 50
  MAX_SPLITS = 6
  CURSOR_VERSION = 1

  def self.definition
    DEFINITION
  end

  def self.runtime_options
    %i[include_pending]
  end

  def self.build(credentials:, settings:, context:)
    new(client: Provider::Redbark.new(api_key: credentials.fetch("api_key")), timezone: context.fetch(:timezone),
      observed_at: context.fetch(:observed_at), include_pending: context.fetch(:configured_options).fetch(:include_pending))
  end

  # Inherited native_ready? stays false until checkpoint translation, source
  # authority and complete multi-window parity have passed operational checks.
  def initialize(client:, timezone:, observed_at:, include_pending:)
    super(client: client)
    raise ArgumentError, "An observation timestamp is required" unless observed_at.is_a?(Time) || observed_at.is_a?(DateTime)
    raise ArgumentError, "include_pending must be explicit" unless [ true, false ].include?(include_pending)
    @timezone = timezone
    @observed_date = observed_at.in_time_zone(timezone).to_date
    @include_pending = include_pending
  end

  def list_accounts(cursor: nil)
    state = inventory_state(cursor)
    response = client.list_accounts_page(offset: state.fetch("offset"))
    body, rows, warnings = envelope(response)
    connections, connection_evidence, connection_warnings = connections_snapshot
    warnings.concat(connection_warnings)
    records = normalize_rows(rows, kind: "account", warnings: warnings) do |raw|
      data = normalized_object(raw)
      connection = connections[data[:connectionId].to_s]
      normalize_account(data, connection: connection) if transactable?(connection&.[](:category))
    end
    next_state = next_offset(body, rows: rows, state: state, page_size: Provider::Redbark::ACCOUNTS_PAGE_SIZE, warnings: warnings)
    warnings << warning("truncated_inventory") if truncated?(response)
    continuation = encode_cursor(next_state) if next_state && warnings.empty?
    Provider::AccountData::Page.new(records: records, mode: "snapshot", next_cursor: continuation,
      complete: next_state.nil? && warnings.empty?, warnings: warnings,
      coverage: { "resource" => "account", "connection_categories" => %w[banking documents unknown] },
      evidence: { "accounts" => response, "connections" => connection_evidence })
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise Provider::AccountData::InvalidResponse, "Redbark balance has no continuation cursor" unless cursor.nil?
    category = metadata(account)[:connection_category]
    unless category.blank? || category == "banking"
      return Provider::AccountData::Page.new(records: [ unavailable_balance(account) ], complete: true, mode: "snapshot",
        coverage: { "resource" => "balance", "supported" => false },
        evidence: { "connection_category" => category, "balance_endpoint_supported" => false })
    end
    # A single account bounds the request and prevents a stale or document
    # account from rejecting a batch of otherwise healthy bank balances.
    response = client.get_balances_snapshot(account_ids: [ account[:external_id] ])
    body, rows, warnings = envelope(response)
    matches = rows.select { |raw| raw.is_a?(Hash) && raw.with_indifferent_access[:accountId].to_s == account[:external_id] }
    warnings << warning("balance_ownership_mismatch") if matches.size != rows.size
    record = if matches.one?
      begin
        normalize_balance(matches.sole, account: account)
      rescue Provider::AccountData::InvalidResponse
        warnings << warning("invalid_balance")
        unavailable_balance(account)
      end
    else
      warnings << warning(matches.empty? ? "missing_balance" : "duplicate_balance")
      unavailable_balance(account)
    end
    warnings << warning("incomplete_balance") if truncated?(response) || pagination(body)[:hasMore] == true
    Provider::AccountData::Page.new(records: [ record ], complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      coverage: { "resource" => "balance" }, evidence: { "response" => response })
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    details = metadata(account)
    connection_id = normalized_id(details.fetch(:connection_id))
    unless transactable?(details[:connection_category])
      raise Provider::AccountData::InvalidResponse, "Redbark connection does not support transactions"
    end
    state = transaction_state(account, connection_id: connection_id, cursor: cursor, window: window)
    segment = state.fetch("segments").first
    response = client.get_transactions_page(connection_id: connection_id, account_id: account[:external_id],
      start_date: Date.iso8601(segment.fetch("start")), end_date: Date.iso8601(segment.fetch("end")),
      include_pending: include_pending, offset: segment.fetch("offset"))
    body, rows, warnings = envelope(response)
    records = []
    recovery = nil
    if truncated?(response)
      if warnings.empty? && split_segment!(state)
        recovery = "split_window"
      else
        warnings << warning("truncated_window")
      end
    else
      records = normalize_rows(rows, kind: "transaction", warnings: warnings) { |raw| normalize_transaction(raw, account: account) }
      next_segment = next_offset(body, rows: rows, state: segment,
        page_size: Provider::Redbark::TRANSACTIONS_PAGE_SIZE, warnings: warnings)
      if next_segment
        state["segments"][0] = next_segment
      else
        state["segments"].shift
      end
    end
    continuation = encode_cursor(state) if state.fetch("segments").any? && warnings.empty?
    Provider::AccountData::Page.new(records: records, complete: state.fetch("segments").empty? && warnings.empty?,
      mode: "snapshot", next_cursor: continuation, warnings: warnings,
      coverage: transaction_coverage(state, segment), evidence: { "response" => response, "recovery" => recovery }.compact)
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Redbark transaction request or response", cause: nil
  end

  def normalize_account(raw, connection: nil)
    data = normalized_object(raw)
    connection = connection ? normalized_object(connection) : {}.with_indifferent_access
    name = data.fetch(:name)
    raise ArgumentError unless name.is_a?(String) && name.present?
    name = "#{data[:institutionName]} - #{name}" if data[:institutionName].present?
    Ingestion::Record.account(external_id: normalized_id(data.fetch(:id)), name: name,
      currency: account_currency(data[:currency]), account_type: data[:type],
      metadata: {
        balance_provided: false, connection_id: data[:connectionId]&.to_s, connection_category: connection[:category],
        account_status: connection[:status], downstream_provider: data[:provider],
        institution: { name: data[:institutionName] || connection[:institutionName], logo: connection[:institutionLogo],
          external_id: connection[:institutionId] }.compact,
        balance_policy: balance_policy
      }, sensitive_details: { account_number: data[:accountNumber] }.compact)
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Redbark account", cause: nil
  end

  def normalize_balance(raw, account:)
    data = normalized_object(raw)
    raise ArgumentError unless normalized_id(data.fetch(:accountId)) == account[:external_id]
    currency = account_currency(data[:currency]) || known_currency(account[:currency]) || raise(ArgumentError)
    Ingestion::Record.account(external_id: account[:external_id], name: account[:name], account_type: account[:account_type],
      currency: currency, balance: decimal(data.fetch(:currentBalance)),
      # The legacy processor uses only currentBalance. Preserve availableBalance
      # as an external observation without interpreting it as available credit.
      available_balance: data[:availableBalance].nil? ? nil : decimal(data[:availableBalance]),
      metadata: metadata(account).merge(balance_provided: true, balance_policy: balance_policy).deep_symbolize_keys)
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Redbark balance", cause: nil
  end

  def normalize_transaction(raw, account:)
    data = normalized_object(raw)
    if data[:accountId].present? && normalized_id(data[:accountId]) != account[:external_id]
      raise ArgumentError
    end
    pending = data[:status].to_s == "pending"
    return nil if pending && !include_pending
    name = data[:merchantName].presence || data[:description].presence || "Transaction"
    raise ArgumentError unless name.is_a?(String)
    merchant = data[:merchantName].to_s.strip.presence
    Ingestion::Record.transaction(external_id: "redbark_#{normalized_id(data.fetch(:id))}",
      amount: -decimal(data.fetch(:amount)), currency: normalized_currency(account[:currency]),
      date: normalized_date(data[:date] || data[:postDate], timezone: timezone), name: name[0..254], pending: pending,
      metadata: {
        notes: data[:description].presence,
        pending_match_policy: !pending ? { source: "redbark", backward_days: 8, amount: "exact", currency: "exact" } : nil,
        merchant: merchant ? { external_id: "redbark_merchant_#{Digest::SHA256.hexdigest(merchant.downcase)[0, 32]}", name: merchant } : nil,
        extra: { "redbark" => { "id" => data[:id], "pending" => pending, "merchant" => data[:merchantName],
          "category" => data[:category], "merchant_category_code" => data[:merchantCategoryCode], "direction" => data[:direction] }.compact }
      })
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Redbark transaction", cause: nil
  end

  def normalize_legacy_account(raw, connection: nil)
    normalize_account(raw, connection: connection)
  end

  def normalize_legacy_transaction(raw, account:)
    normalize_transaction(legacy_decimals(raw, %i[amount]), account: account)
  end

  def normalize_legacy_balance(raw, account:)
    normalize_balance(legacy_decimals(raw, %i[currentBalance availableBalance]), account: account)
  end

  private
    attr_reader :timezone, :observed_date, :include_pending

    def connections_snapshot
      return @connections_snapshot if defined?(@connections_snapshot)
      response = client.list_connections_snapshot
      body, rows, warnings = envelope(response)
      warnings << warning("incomplete_connections") if truncated?(response) || pagination(body)[:hasMore] == true
      pairs = rows.filter_map do |raw|
        data = normalized_object(raw)
        [ normalized_id(data.fetch(:id)), data ]
      rescue KeyError, TypeError, ArgumentError
        warnings << warning("invalid_connection")
        nil
      end
      duplicates = pairs.group_by(&:first).select { |_, values| values.size > 1 }.keys
      warnings << warning("duplicate_connection") if duplicates.any?
      @connections_snapshot = [ pairs.reject { |id, _| duplicates.include?(id) }.to_h, response, warnings ]
    rescue Provider::Redbark::AuthenticationError
      raise
    rescue Provider::Redbark::Error, Provider::AccountData::InvalidResponse
      @connections_snapshot = [ {}, { "status" => "unavailable" }, [ warning("connections_unavailable") ] ]
    end

    def envelope(value)
      data = normalized_object(value)
      body = normalized_object(data.fetch(:response))
      raise ArgumentError unless body[:data].is_a?(Array)
      pagination(body)
      warnings = []
      warnings << warning("provider_error") if body[:error].present? || body[:errors].present?
      [ body, body[:data], warnings ]
    rescue KeyError, TypeError, NoMethodError, ArgumentError
      raise Provider::AccountData::InvalidResponse, "Invalid Redbark response envelope", cause: nil
    end

    def pagination(body)
      values = body.key?(:pagination) ? normalized_object(body[:pagination]) : {}.with_indifferent_access
      if values.key?(:hasMore) && ![ true, false ].include?(values[:hasMore])
        raise ArgumentError, "Invalid Redbark pagination"
      end
      values
    end

    def truncated?(response)
      value = normalized_object(response).fetch(:pagination_headers, {}).with_indifferent_access["x-redbark-truncated"]
      raise ArgumentError unless value.nil? || %w[true false].include?(value)
      value == "true"
    end

    def normalize_rows(rows, kind:, warnings:)
      records = rows.filter_map do |raw|
        yield raw
      rescue Provider::AccountData::InvalidResponse, KeyError, ArgumentError, TypeError
        warnings << warning("invalid_#{kind}")
        nil
      end
      grouped = records.group_by { |record| record[:external_id] }
      if kind == "transaction"
        # Legacy merge assigns new observations by ID in response order.
        grouped.values.map(&:last)
      else
        warnings << warning("duplicate_#{kind}") if grouped.any? { |_, values| values.size > 1 }
        grouped.values.filter_map { |values| values.sole if values.one? }
      end
    end

    def next_offset(body, rows:, state:, page_size:, warnings:)
      if rows.size > page_size
        warnings << warning("oversized_page")
        return
      end
      paging = pagination(body)
      unless paging.key?(:hasMore)
        warnings << warning("missing_pagination")
        return
      end
      if paging.key?(:offset) && paging[:offset] != state.fetch("offset")
        warnings << warning("page_offset_mismatch")
      end
      total = paging.key?(:total) ? paging[:total] : body[:total]
      unless total.nil?
        observed = state.fetch("offset") + rows.size
        if !total.is_a?(Integer) || total < observed || (!paging[:hasMore] && total != observed) || (paging[:hasMore] && total <= observed)
          warnings << warning("reported_total_mismatch")
        end
      end
      return unless paging[:hasMore]
      if rows.empty? || state.fetch("pages") + 1 >= MAX_PAGES
        warnings << warning(rows.empty? ? "empty_continuation" : "page_limit")
        return
      end
      state.merge("offset" => state.fetch("offset") + rows.size, "pages" => state.fetch("pages") + 1)
    end

    def inventory_state(cursor)
      state = cursor ? decode_cursor(cursor) : { "version" => CURSOR_VERSION, "kind" => "accounts", "offset" => 0, "pages" => 0 }
      unless state.keys.sort == %w[kind offset pages version] && state["kind"] == "accounts" && valid_offset?(state, Provider::Redbark::ACCOUNTS_PAGE_SIZE)
        raise Provider::AccountData::InvalidResponse, "Invalid Redbark inventory cursor"
      end
      state
    end

    def transaction_state(account, connection_id:, cursor:, window:)
      scope = normalized_object(window || {})
      from = if scope[:checkpoint_covered_through].present? && scope[:initial] == false
        normalized_date(scope[:checkpoint_covered_through], timezone: timezone) - 7
      else
        scope[:start] ? normalized_date(scope[:start], timezone: timezone) : observed_date - 90
      end
      through = scope[:end] ? normalized_date(scope[:end], timezone: timezone) : observed_date
      raise ArgumentError unless from <= through
      base = { "version" => CURSOR_VERSION, "kind" => "transactions", "account_id" => account[:external_id],
        "connection_id" => connection_id, "pending" => include_pending, "start" => from.iso8601, "end" => through.iso8601 }
      return base.merge("segments" => [ new_segment(from, through, 0) ]) unless cursor
      state = decode_cursor(cursor)
      raise ArgumentError unless state.except("segments") == base
      segments = state.fetch("segments")
      raise ArgumentError unless segments.is_a?(Array) && segments.size.between?(1, MAX_SPLITS + 1)
      previous_end = nil
      segments.each do |segment|
        raise ArgumentError unless segment.is_a?(Hash) && segment.keys.sort == %w[depth end offset pages start]
        first, last = Date.iso8601(segment.fetch("start")), Date.iso8601(segment.fetch("end"))
        unless first >= from && last <= through && first <= last && (!previous_end || first == previous_end + 1) &&
            segment["depth"].is_a?(Integer) && segment["depth"].between?(0, MAX_SPLITS) && valid_offset?(segment, Provider::Redbark::TRANSACTIONS_PAGE_SIZE)
          raise ArgumentError
        end
        previous_end = last
      end
      raise ArgumentError unless previous_end == through
      state
    end

    def valid_offset?(state, page_size)
      state["pages"].is_a?(Integer) && state["pages"].between?(0, MAX_PAGES - 1) &&
        state["offset"].is_a?(Integer) && state["offset"].between?(state["pages"], state["pages"] * page_size)
    end

    def split_segment!(state)
      segment = state.fetch("segments").first
      from, through = Date.iso8601(segment.fetch("start")), Date.iso8601(segment.fetch("end"))
      return false if from >= through || segment.fetch("depth") >= MAX_SPLITS
      middle = from + ((through - from) / 2).to_i
      state["segments"].shift
      state["segments"].unshift(new_segment(from, middle, segment.fetch("depth") + 1),
        new_segment(middle + 1, through, segment.fetch("depth") + 1))
      true
    end

    def new_segment(from, through, depth)
      { "start" => from.iso8601, "end" => through.iso8601, "depth" => depth, "offset" => 0, "pages" => 0 }
    end

    def transaction_coverage(state, segment)
      zone = Time.find_zone!(timezone)
      from, through = Date.iso8601(state.fetch("start")), Date.iso8601(state.fetch("end"))
      { "resource" => "transaction", "start" => zone.local(from.year, from.month, from.day).utc.iso8601,
        "end" => zone.local(through.year, through.month, through.day).end_of_day.utc.iso8601,
        "page_start" => segment.fetch("start"), "page_end" => segment.fetch("end"),
        "pending_included" => include_pending, "pending_absence_authoritative" => false }
    end

    def encode_cursor(value)
      Base64.strict_encode64(JSON.generate(value))
    end

    def decode_cursor(value)
      raise ArgumentError unless value.is_a?(String) && value.bytesize <= 8192
      state = JSON.parse(Base64.strict_decode64(value))
      raise ArgumentError unless state.is_a?(Hash) && state["version"] == CURSOR_VERSION
      state
    rescue JSON::ParserError, TypeError, ArgumentError
      raise Provider::AccountData::InvalidResponse, "Invalid Redbark continuation cursor", cause: nil
    end

    def transactable?(category)
      category.blank? || %w[banking documents].include?(category)
    end

    def metadata(account)
      (account[:metadata] || {}).with_indifferent_access
    end

    def balance_policy
      { debt_transform: "negate", debt_types: %w[CreditCard Loan], cash_balance: "balance", current_anchor: true }
    end

    def unavailable_balance(account)
      Ingestion::Record.account(external_id: account[:external_id], name: account[:name], currency: account[:currency],
        account_type: account[:account_type], metadata: metadata(account).merge(balance_provided: false).deep_symbolize_keys)
    end

    def account_currency(value)
      value = value.with_indifferent_access[:code] if value.is_a?(Hash)
      known_currency(value)
    end

    def legacy_decimals(raw, fields)
      data = normalized_object(raw).deep_dup
      fields.each do |key|
        data[key] = BigDecimal(data[key].to_s) if data[key].is_a?(Float) && data[key].finite?
      end
      data
    end

    def warning(code)
      { "code" => code, "provider_key" => "redbark" }
    end
end
