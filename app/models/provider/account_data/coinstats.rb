require "base64"
require "digest"
require "json"

# CoinStats routes an existing credential through wallet, exchange and DeFi
# endpoints. Reviewed descriptors identify those scopes; monetary snapshots do not.
class Provider::AccountData::Coinstats < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  PAGE_SIZE = Provider::Coinstats::IngestionClient::PAGE_SIZE
  MAX_ROWS = 10_000
  MAX_CURSOR_BYTES = 2.megabytes
  REQUESTS_PER_STREAM = 20
  DEFINITION = Provider::AccountData::Definition.new(
    key: "coinstats", source: "coinstats", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "api_key", type: "string", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [ "currency", "sensitive_details.source_descriptor" ], frozen: [ "name" ], inventory: "all" }
  end

  def self.context_sources
    %i[external_accounts exchange_rate_resolver]
  end

  def self.build(credentials:, settings:, context:)
    new(client: Provider::Coinstats::IngestionClient.new(api_key: credentials.fetch("api_key")),
      external_accounts: context.fetch(:external_accounts), exchange_rate_resolver: context.fetch(:exchange_rate_resolver),
      timezone: context.fetch(:timezone), family_currency: context.fetch(:family_currency), observed_at: context.fetch(:observed_at))
  end

  def initialize(client:, external_accounts:, exchange_rate_resolver:, timezone:, family_currency:, observed_at:)
    super(client: client)
    @timezone, @family_currency, @observed_at = timezone, normalized_currency(family_currency), observed_at.to_time
    @external_accounts = external_accounts.map { |row| normalized_object(row) }
    raise ArgumentError if @external_accounts.size > MAX_ROWS
    @values = Values.new(exchange_rate_resolver: exchange_rate_resolver, observed_at: @observed_at, timezone: timezone)
    @snapshots, @requests, @wallet_responses, @defi_responses = {}, Hash.new(0), {}, {}
  end

  def list_accounts(cursor: nil)
    raise ArgumentError unless cursor.nil?
    warnings, seen = [], {}
    records = @external_accounts.filter_map do |row|
      descriptor = descriptor_for(row)
      raise ArgumentError if seen[row[:external_id]]
      seen[row[:external_id]] = true
      Ingestion::Record.account(external_id: row[:external_id], name: row.fetch(:name), currency: row[:currency],
        account_type: descriptor.fetch("source"), metadata: { balance_provided: false },
        sensitive_details: { source_descriptor: descriptor })
    rescue ArgumentError, KeyError, TypeError, NoMethodError
      warnings << warning("account_source_descriptor_invalid")
      nil
    end
    Provider::AccountData::Page.new(records: records, complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      coverage: { "resource" => "account", "absence_authoritative" => false, "discovery" => "reviewed_existing_sources" })
  rescue ArgumentError
    raise Provider::AccountData::InvalidResponse, "Invalid CoinStats inventory", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    descriptor = descriptor_for(account)
    state = balance_state(account, descriptor, cursor)
    consume_request!(account, "balance")
    response, coins = case descriptor.fetch("source")
    when "exchange"
      raw = client.portfolio_coins(portfolio_id: descriptor.fetch("portfolio_id"), page: state.fetch("page"))
      [ raw, paginated_rows(raw, state.fetch("page")) ]
    when "wallet"
      raw = wallet_response(descriptor)
      [ raw, wallet_coins(raw, descriptor) ]
    when "defi"
      raw = defi_response(descriptor)
      [ raw, defi_coins(raw, descriptor) ]
    end
    combined = state.fetch("coins") + coins
    raise ArgumentError if combined.size > MAX_ROWS
    coin_ids = combined.map { |coin| @values.coin_identity(coin) }
    raise ArgumentError if coin_ids.uniq.size != coin_ids.size
    if descriptor.fetch("source") == "exchange" && coins.size == PAGE_SIZE
      continuation = encode_cursor(state.merge("page" => state.fetch("page") + 1, "coins" => combined))
      return Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
        next_cursor: continuation, progress_cursor: continuation, evidence: { "response" => response },
        coverage: { "resource" => "balance", "end" => state.fetch("observed_at") })
    end
    # A continued portfolio is anchored to the first request's observation date,
    # even when a subsequent job completes its last page after midnight.
    valuation = @values.snapshot(combined, descriptor: descriptor, family_currency: @family_currency,
      observed_at: state.fetch("observed_at"), account_currency: account[:currency])
    @snapshots[account[:external_id]] = valuation
    record = Ingestion::Record.account(external_id: account[:external_id], name: account[:name],
      currency: valuation.fetch("currency"), balance: decimal(valuation.fetch("balance")),
      cash_balance: decimal(valuation.fetch("cash_balance")), balance_date: Date.iso8601(valuation.fetch("date")),
      sensitive_details: { source_descriptor: descriptor, coinstats_valuation: valuation },
      metadata: { balance_provided: true, balance_policy: { current_anchor: true, anchor_date: "balance_date" } })
    Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot",
      evidence: { "response" => response, "valuation" => valuation },
      coverage: { "resource" => "balance", "end" => state.fetch("observed_at") })
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid or incomplete CoinStats balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    descriptor = descriptor_for(account)
    unless normalized_object(account[:metadata] || {})[:linked_account_type] == "Crypto"
      return Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot",
        coverage: { "resource" => "holding", "supported" => false })
    end
    valuation = @snapshots[account[:external_id]] || normalized_object(account[:sensitive_details] || {})[:coinstats_valuation]
    unless valuation.is_a?(Hash) && valuation["version"] == 1 && valuation["observed_at"] == @observed_at.iso8601(9) &&
        valuation["descriptor_fingerprint"] == descriptor_fingerprint(descriptor)
      raise Provider::AccountData::IncompletePage, "CoinStats holdings require a current complete valuation"
    end
    records = valuation.fetch("positions").map do |position|
      Ingestion::Record.holding(external_id: position.fetch("external_id"), date: Date.iso8601(valuation.fetch("date")),
        currency: valuation.fetch("currency"), quantity: decimal(position.fetch("quantity")),
        price: decimal(position.fetch("price")), amount: decimal(position.fetch("amount")),
        security: { ticker: position.fetch("ticker"), name: position.fetch("name") },
        metadata: { cost_basis: position["cost_basis"] && decimal(position.fetch("cost_basis")), delete_future_holdings: false })
    end
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", evidence: { "valuation" => valuation },
      coverage: { "resource" => "holding", "end" => valuation.fetch("observed_at"), "absence_authoritative" => false,
        "legacy_same_day_pruning" => descriptor.fetch("portfolio_account") })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid CoinStats holdings", cause: nil
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    descriptor = descriptor_for(account)
    if descriptor.fetch("source") == "defi"
      return Provider::AccountData::Page.new(records: [], complete: true, mode: "delta",
        coverage: { "resource" => "activity", "supported" => false })
    end
    state = history_state(account, descriptor, cursor, window)
    consume_request!(account, "activity")
    args = { currency: state.fetch("currency"), page: state.fetch("page"), from: state["start"], to: state.fetch("end") }
    response = if descriptor.fetch("source") == "wallet"
      client.wallet_transactions(address: descriptor.fetch("address"), blockchain: descriptor.fetch("blockchain"), **args)
    else
      # Exchange and portfolio histories cannot be mixed after pages have been
      # published. A reviewed generation-level fallback must restart the stream.
      client.exchange_transactions(portfolio_id: descriptor.fetch("portfolio_id"), **args)
    end
    rows = paginated_rows(response, state.fetch("page"))
    warnings, ids = [], []
    records = rows.filter_map do |raw|
      identity = Activity.identity(raw)
      raise ArgumentError if ids.include?(identity) || state.fetch("seen_ids").include?(identity)
      ids << identity
      normalizer = activity_normalizer(account, descriptor, state.fetch("currency"))
      next unless normalizer.relevant?(raw)
      normalizer.normalize(raw)
    rescue ArgumentError, Provider::AccountData::InvalidResponse, KeyError, TypeError, NoMethodError
      warnings << warning("invalid_or_repeated_activity")
      nil
    end
    warnings << warning("empty_history_requires_readiness") if rows.empty? && state.fetch("page") == 1
    complete = rows.size < PAGE_SIZE && warnings.empty?
    continuation = if rows.size == PAGE_SIZE && warnings.empty?
      all_ids = state.fetch("seen_ids") + ids
      raise ArgumentError if all_ids.size > MAX_ROWS
      encode_cursor(state.merge("page" => state.fetch("page") + 1, "seen_ids" => all_ids))
    end
    Provider::AccountData::Page.new(records: records, complete: complete, mode: "delta", warnings: warnings,
      next_cursor: continuation, progress_cursor: continuation, evidence: { "response" => response },
      coverage: { "resource" => "activity", "start" => state["start"], "end" => state.fetch("end"),
        "pending_absence_authoritative" => false }.compact)
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid CoinStats activities", cause: nil
  end

  def normalize_activity(raw, account:)
    activity_normalizer(account, descriptor_for(account), normalized_currency(account[:currency])).normalize(raw)
  end

  # Archived JSON used Float before the exact reader existed. Identity spelling
  # is retained separately; only its financial values receive exact conversion.
  def normalize_legacy_activity(raw, account:)
    normalizer = activity_normalizer(account, descriptor_for(account), normalized_currency(account[:currency]))
    normalizer.normalize(Activity.exact_legacy_values(raw), identity: Activity.identity(raw))
  end

  private
    def descriptor_for(account)
      details = account[:sensitive_details]
      descriptor = SourceDescriptor.validate!(normalized_object(details || {}).fetch(:source_descriptor))
      expected = JSON.generate([ [ "account_id", descriptor.fetch("asset_id") ], [ "wallet_address", descriptor["wallet_address"] ] ])
      raise ArgumentError unless account[:external_id] == expected
      descriptor
    end

    def activity_normalizer(account, descriptor, currency)
      Activity.new(descriptor: descriptor, account_name: account[:name], currency: currency, timezone: @timezone)
    end

    def balance_state(account, descriptor, cursor)
      if cursor
        raise ArgumentError unless descriptor.fetch("source") == "exchange"
        state = decode_cursor(cursor)
        raise ArgumentError unless state.keys.sort == %w[account coins descriptor_fingerprint observed_at page resource version].sort && state["version"] == 1 &&
          state["resource"] == "balance" && state["account"] == account[:external_id] && state["coins"].is_a?(Array) &&
          state["descriptor_fingerprint"] == descriptor_fingerprint(descriptor) &&
          state["page"].is_a?(Integer) && state["page"].between?(2, MAX_ROWS / PAGE_SIZE + 1)
        raise ArgumentError unless Time.iso8601(state.fetch("observed_at")) <= @observed_at
        state
      else
        { "version" => 1, "resource" => "balance", "account" => account[:external_id], "page" => 1,
          "observed_at" => @observed_at.iso8601(9), "coins" => [], "descriptor_fingerprint" => descriptor_fingerprint(descriptor) }
      end
    end

    def history_state(account, descriptor, cursor, window)
      code = normalized_currency(account[:currency])
      if cursor
        state = decode_cursor(cursor)
        raise ArgumentError unless state.keys.sort == %w[account currency descriptor_fingerprint end page resource seen_ids source start version].sort &&
          state["version"] == 1 && state["resource"] == "activity" && state["account"] == account[:external_id] &&
          state["descriptor_fingerprint"] == descriptor_fingerprint(descriptor) &&
          state["source"] == descriptor.fetch("source") && state["currency"] == code &&
          state["page"].is_a?(Integer) && state["page"].between?(2, MAX_ROWS / PAGE_SIZE + 1) &&
          state["seen_ids"].is_a?(Array) && state["seen_ids"].size <= MAX_ROWS && state["seen_ids"].all? { |id| id.is_a?(String) }
      else
        requested = normalized_object(window || {})
        start = requested[:start] if requested[:explicit_start] == true || requested[:initial] == false
        state = { "version" => 1, "resource" => "activity", "account" => account[:external_id], "source" => descriptor.fetch("source"),
          "currency" => code, "page" => 1, "start" => start, "end" => requested[:end] || @observed_at.iso8601(9), "seen_ids" => [],
          "descriptor_fingerprint" => descriptor_fingerprint(descriptor) }
      end
      finish = Time.iso8601(state.fetch("end"))
      raise ArgumentError if finish > @observed_at || (state["start"] && Time.iso8601(state.fetch("start")) > finish)
      state
    end

    def paginated_rows(response, page)
      object = normalized_object(response)
      rows = bounded_array(object.fetch(:result), limit: PAGE_SIZE)
      if object[:meta]
        meta = normalized_object(object[:meta])
        raise ArgumentError if meta[:page] && meta[:page] != page
        raise ArgumentError if meta[:limit] && meta[:limit] != PAGE_SIZE
      end
      rows.map { |row| normalized_object(row) }
    end

    def wallet_response(descriptor)
      key = descriptor.values_at("address", "blockchain")
      @wallet_responses[key] ||= client.wallet_balances(address: key.first, blockchain: key.last)
    end

    def wallet_coins(response, descriptor)
      wallets = bounded_array(response)
      matches = wallets.map { |raw| normalized_object(raw) }.select do |wallet|
        wallet[:address] == descriptor.fetch("address") &&
          (wallet[:connectionId] || wallet[:blockchain]) == descriptor.fetch("blockchain")
      end
      raise ArgumentError unless matches.one?
      bounded_array(matches.sole.fetch(:balances)).map { |row| normalized_object(row) }
    end

    def defi_response(descriptor)
      key = descriptor.values_at("address", "blockchain")
      @defi_responses[key] ||= client.wallet_defi(address: key.first, blockchain: key.last)
    end

    def defi_coins(response, descriptor)
      protocols = bounded_array(normalized_object(response).fetch(:protocols))
      positions = protocols.flat_map do |raw_protocol|
        protocol = normalized_object(raw_protocol)
        bounded_array(protocol.fetch(:investments)).flat_map do |raw_investment|
          investment = normalized_object(raw_investment)
          bounded_array(investment.fetch(:assets)).map do |raw_asset|
            asset = normalized_object(raw_asset)
            asset.merge("id" => Values.defi_identity(protocol, investment, asset, blockchain: descriptor.fetch("blockchain")),
              "defi_total_value" => asset.fetch(:price))
          end
        end
      end
      raise ArgumentError if positions.size > MAX_ROWS
      matches = positions.select { |row| row[:id] == descriptor.fetch("asset_id") }
      # Disappearance is meaningful only for a fully understood response. A
      # separate reviewed absence policy must authorize zeroing a closed position.
      raise ArgumentError unless matches.one?
      matches
    end

    def bounded_array(value, limit: MAX_ROWS)
      raise ArgumentError unless value.is_a?(Array) && value.size <= limit
      value
    end

    def consume_request!(account, stream)
      key = [ account[:external_id], stream ]
      if @requests[key] >= REQUESTS_PER_STREAM
        raise Provider::AccountData::IncompletePage, "CoinStats request budget exhausted; saved progress can resume"
      end
      @requests[key] += 1
    end

    def encode_cursor(state)
      json = JSON.generate(Activity.decimal_strings(state))
      raise ArgumentError if json.bytesize > MAX_CURSOR_BYTES
      Base64.strict_encode64(json)
    end

    def decode_cursor(cursor)
      raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= MAX_CURSOR_BYTES * 2
      json = Base64.strict_decode64(cursor)
      raise ArgumentError if json.bytesize > MAX_CURSOR_BYTES
      JSON.parse(json, decimal_class: BigDecimal)
    end

    def warning(code)
      { "code" => code, "provider_key" => "coinstats" }
    end

    def descriptor_fingerprint(descriptor)
      Digest::SHA256.hexdigest(JSON.generate(descriptor.sort.to_h))
    end
end
