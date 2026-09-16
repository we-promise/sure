require "base64"
require "json"

class Provider::AccountData::OnchainWallet < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  PAGE_SIZE = 100
  DEFINITION = Provider::AccountData::Definition.new(key: "onchain_wallet", source: "onchain_wallet", credential_scope: "connection",
    capabilities: %w[holdings activities], fields: [ { name: "etherscan_api_key", type: "string", secret: true } ])

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: %w[currency sensitive_details.source_descriptor], frozen: %w[name], inventory: "all" }
  end

  def self.context_sources
    %i[external_accounts connection_details onchain_configuration onchain_fx_credentials onchain_capture]
  end

  def self.frozen_context_sources
    %i[onchain_capture]
  end

  def progress_cursor_scope(stream:)
    %w[accounts activities].include?(stream) ? :sync : :connection
  end

  def self.build(credentials:, settings:, context:)
    configuration = context.fetch(:onchain_configuration)
    fx_reader = FxReader.new(options: configuration.fetch("fx"), credentials: context.fetch(:onchain_fx_credentials))
    client = Client.new(configuration: configuration, credentials: credentials, fx_resolver: CachedExchangeRateResolver.new, fx_reader: fx_reader)
    new(external_accounts: context.fetch(:external_accounts), observed_at: context.fetch(:observed_at), timezone: context.fetch(:timezone),
      locale: context.fetch(:family_locale), sync_start_date: context.fetch(:connection_details)[:sync_start_date],
      client: client, configuration: configuration, capture: context.fetch(:onchain_capture), keyed_history: credentials.with_indifferent_access[:etherscan_api_key].present?)
  end

  def initialize(external_accounts:, observed_at:, timezone:, locale:, sync_start_date: nil, client: nil, configuration: nil, capture: nil, keyed_history: false)
    super(client: client)
    raise ArgumentError unless external_accounts.is_a?(Array)
    @observed_at, @timezone, @locale = observed_at.to_time, timezone, locale
    @sync_start_date = sync_start_date && date_in_zone(sync_start_date.to_s)
    @sources = external_accounts.map do |external|
      row = external.with_indifferent_access
      descriptor = SourceDescriptor.validate!(row.fetch(:sensitive_details).fetch("source_descriptor"))
      raise ArgumentError unless SourceDescriptor.external_id(descriptor) == row.fetch(:external_id)
      { external: row, descriptor: descriptor }
    end.sort_by { |source| source.fetch(:external).fetch(:external_id) }
    raise ArgumentError unless @sources.map { |source| source[:external][:external_id] }.uniq.size == @sources.size
    @selection_digest = Digest::SHA256.hexdigest(JSON.generate(@sources.map { |source| source[:external][:external_id] }))
    @snapshots, @prices = {}, {}
    @feeder = Feeder.new(client: client, sources: @sources, configuration: configuration, capture: capture,
      observed_at: @observed_at, timezone: timezone, sync_start_date: @sync_start_date, keyed_history: keyed_history) if client
  rescue ArgumentError, TypeError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid tracked on-chain asset inventory", cause: nil
  end

  def list_accounts(cursor: nil)
    if @feeder
      progress = @feeder.advance(cursor: cursor)
      return progress if progress
      offset = @feeder.inventory_offset(cursor)
    else
      offset = cursor ? decode_cursor(cursor, resource: "inventory", fingerprint: @selection_digest) : 0
    end
    rows = @sources.slice(offset, PAGE_SIZE)
    raise ArgumentError unless rows
    continuation = if offset + rows.size < @sources.size
      @feeder ? @feeder.cursor(offset: offset + rows.size) : encode_cursor(resource: "inventory", fingerprint: @selection_digest, offset: offset + rows.size)
    end
    Provider::AccountData::Page.new(records: rows.map { |source| account_record(source) }, complete: continuation.nil?, mode: "snapshot",
      next_cursor: continuation, progress_cursor: continuation,
      coverage: { "scope" => "user_selected_assets", "absence_authoritative" => false }, evidence: @feeder ? @feeder.evidence : {})
  rescue ArgumentError, TypeError, KeyError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid tracked on-chain inventory page", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    source = source_for(account)
    snapshot, asset, quantity = asset_snapshot(source)
    price = quantity&.zero? ? BigDecimal("0") : prices_for(source, snapshot)&.current
    known = !quantity.nil? && !price.nil?
    record = account_record(source, snapshot: snapshot, asset: asset, quantity: quantity,
      balance: known ? (quantity * price).round(4) : nil)
    Provider::AccountData::Page.new(records: [ record ], complete: known, mode: "snapshot", evidence: evidence(source, snapshot),
      coverage: { "end" => observation_date.iso8601, "absence_authoritative" => false }, warnings: known ? [] : [ { "code" => "asset_valuation_unavailable" } ])
  rescue ArgumentError, TypeError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid on-chain balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    source = source_for(account)
    snapshot, asset, quantity = asset_snapshot(source)
    security = security_descriptor(source, asset)
    price = quantity&.zero? ? BigDecimal("0") : prices_for(source, snapshot)&.current
    known = quantity && price && security
    records = known ? [ Ingestion::Record.holding(external_id: source[:descriptor].fetch("ingestion_namespace"),
      security: security, date: observation_date, currency: currency_for(source), quantity: quantity,
      price: price, amount: (quantity * price).round(4), metadata: { delete_future_holdings: false }) ] : []
    Provider::AccountData::Page.new(records: records, complete: !!known, mode: "snapshot", evidence: evidence(source, snapshot),
      coverage: { "end" => observation_date.iso8601, "absence_authoritative" => false }, warnings: known ? [] : [ { "code" => "asset_valuation_unavailable" } ])
  rescue ArgumentError, TypeError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid on-chain holding", cause: nil
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    source = source_for(account)
    snapshot, asset, = asset_snapshot(source)
    namespace = source[:descriptor].fetch("ingestion_namespace")
    offset = cursor ? decode_cursor(cursor, resource: "activities", fingerprint: snapshot.fingerprint, account: account[:external_id]) : 0
    rows = snapshot.movements_for(source[:descriptor]).select { |row| row["date"].nil? || !@sync_start_date || date_in_zone(row["date"]) >= @sync_start_date }
      .sort_by { |row| [ row["date"].to_s, row["external_id"] ] }
    identities = rows.map { |row| row.fetch("external_id") }
    raise ArgumentError unless identities.uniq == identities
    slice = rows.slice(offset, PAGE_SIZE)
    raise ArgumentError unless slice
    warnings = []
    records = slice.filter_map do |row|
      if row["date"].nil?
        warnings << { "code" => "movement_date_unavailable", "external_id" => row.fetch("external_id") }
        next
      end
      quantity = decimal(row.fetch("amount"))
      next if quantity.zero?
      date = date_in_zone(row.fetch("date"))
      raise ArgumentError if date > observation_date
      price = prices_for(source, snapshot)&.on(date)
      security = security_descriptor(source, asset)
      unless price && security
        warnings << { "code" => "movement_price_unavailable", "external_id" => row.fetch("external_id") }
        next
      end
      Ingestion::Record.activity(external_id: "#{namespace}_#{row.fetch('external_id')}", activity_type: "transfer", ledger_type: "trade",
        security: security, quantity: quantity, price: price, amount: -(quantity * price).round(4), currency: currency_for(source), date: date,
        name: movement_name(quantity, source, asset), metadata: { investment_activity_label: "Transfer",
          extra: { onchain_wallet: row } })
    end
    continuation = if offset + slice.size < rows.size && warnings.empty?
      encode_cursor(resource: "activities", fingerprint: snapshot.fingerprint, account: account[:external_id], offset: offset + slice.size)
    end
    warnings << { "code" => "history_truncated" } if snapshot.history_truncated?
    warnings << { "code" => "asset_inventory_truncated" } if asset.nil? && snapshot.assets_truncated?
    Provider::AccountData::Page.new(records: records, complete: continuation.nil? && warnings.empty?, mode: "delta",
      next_cursor: continuation, progress_cursor: continuation, warnings: warnings, evidence: evidence(source, snapshot).merge("movements" => slice),
      coverage: { "start" => @sync_start_date&.iso8601, "end" => observation_date.iso8601, "pending_absence_authoritative" => false })
  rescue ArgumentError, TypeError, KeyError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid on-chain movement page", cause: nil
  end

  private
    def source_for(account)
      @sources.find { |source| source[:external][:external_id] == account[:external_id] } || raise(ArgumentError)
    end

    def asset_snapshot(source)
      descriptor = source.fetch(:descriptor)
      key = [ descriptor.fetch("chain"), descriptor.fetch("wallet_address") ]
      raw = @feeder ? @feeder.snapshot(descriptor) : source[:external].fetch(:sensitive_details)["onchain_snapshot"]
      unless raw
        raise Provider::AccountData::IncompletePage, "A sealed on-chain wallet snapshot is required"
      end
      snapshot = SnapshotArchive.new(raw)
      unless snapshot.chain == key.first && snapshot.address == key.last && snapshot.observed_at == @observed_at
        raise Provider::AccountData::IncompletePage, "On-chain snapshot does not match this wallet sync"
      end
      if @snapshots[key] && @snapshots[key].fingerprint != snapshot.fingerprint
        raise Provider::AccountData::IncompletePage, "Tracked assets at one address require the same wallet snapshot"
      end
      snapshot = @snapshots[key] ||= snapshot
      asset = snapshot.asset_for(descriptor)
      quantity = asset ? decimal(asset.fetch("quantity")) : (snapshot.assets_truncated? ? nil : BigDecimal("0"))
      [ snapshot, asset, quantity ]
    end

    def prices_for(source, snapshot)
      key = source[:external].fetch(:external_id)
      return @prices[key] if @prices.key?(key)
      raw = @feeder ? @feeder.quotes(key) : source[:external].fetch(:sensitive_details)["onchain_prices"]
      asset = snapshot.asset_for(source.fetch(:descriptor))
      ticker = security_descriptor(source, asset)&.fetch(:ticker)
      @prices[key] = raw && Quotes.new(raw, snapshot: snapshot, currency: currency_for(source), observed_at: @observed_at.in_time_zone(@timezone),
        external_id: key, ticker: ticker)
    end

    def account_record(source, snapshot: nil, asset: nil, quantity: nil, balance: nil)
      descriptor = source.fetch(:descriptor)
      Ingestion::Record.account(external_id: source[:external].fetch(:external_id), name: source[:external].fetch(:name),
        currency: currency_for(source), account_type: "Crypto", balance: balance,
        cash_balance: balance.nil? ? nil : BigDecimal("0"), balance_date: balance.nil? ? nil : observation_date,
        metadata: { balance_provided: !balance.nil?, ingestion_namespace: descriptor.fetch("ingestion_namespace"),
          asset: { code: asset&.fetch("symbol") || descriptor.fetch("symbol"), quantity: quantity&.to_s("F") },
          balance_policy: { cash_balance: "cash_balance" } },
        sensitive_details: { "source_descriptor" => descriptor })
    end

    def currency_for(source)
      normalized_currency(source[:external].fetch(:currency))
    end

    def observation_date
      @observed_at.in_time_zone(@timezone).to_date
    end

    def security_descriptor(source, asset)
      symbol = asset&.fetch("symbol") || source[:descriptor].fetch("symbol")
      canonical = Onchain::AssetSymbol.canonical(symbol)
      return nil unless Onchain::SecurityResolver::SYMBOL_PATTERN.match?(canonical)
      { lookup: "onchain_asset", ticker: "CRYPTO:#{canonical}", symbol: symbol, name: asset&.fetch("name") || source[:descriptor].fetch("name") }
    end

    def movement_name(quantity, source, asset)
      I18n.t("onchain_wallet_item.movement.#{quantity.positive? ? 'received' : 'sent'}", locale: @locale,
        quantity: quantity.abs.round(8).to_s("F"), symbol: asset&.fetch("symbol") || source[:descriptor].fetch("symbol"))
    end

    def evidence(source, snapshot)
      { "snapshot_sha256" => snapshot.fingerprint, "observed_at" => snapshot.observed_at.iso8601(9),
        "asset" => snapshot.asset_for(source.fetch(:descriptor)), "prices" => prices_for(source, snapshot)&.evidence, "locale" => @locale.to_s }
    end

    def decimal(value)
      SnapshotArchive.decimal(value)
    end

    def encode_cursor(resource:, fingerprint:, offset:, account: nil)
      Base64.urlsafe_encode64(JSON.generate(version: 1, resource: resource, fingerprint: fingerprint, account: account, offset: offset), padding: false)
    end

    def decode_cursor(cursor, resource:, fingerprint:, account: nil)
      raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 4096
      data = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless data.is_a?(Hash) && data.keys.sort == %w[account fingerprint offset resource version] && data["version"] == 1 &&
          data["resource"] == resource && data["fingerprint"] == fingerprint && data["account"] == account && data["offset"].is_a?(Integer) && data["offset"] >= 0
        raise ArgumentError
      end
      data["offset"]
    end
end
