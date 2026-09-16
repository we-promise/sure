# A pure deterministic response consumer. Calling next_operation never performs
# HTTP; it either requests one missing input or exposes a completely assembled
# immutable snapshot/quote set. Every branch is replayed from captured responses.
class Provider::AccountData::OnchainWallet::Assembly
  Archive = Provider::AccountData::OnchainWallet::CaptureArchive
  Snapshot = Provider::AccountData::OnchainWallet::SnapshotArchive
  MAX_OPERATIONS = Archive::MAX_BATCHES - 100
  attr_reader :snapshots, :quotes, :operations

  def initialize(sources:, configuration:, observed_at:, timezone:, sync_start_date:, keyed_history:, capture_reference: nil)
    @sources, @configuration, @observed_at, @timezone = sources, configuration, observed_at, timezone
    @sync_start_date, @keyed_history = sync_start_date, keyed_history
    @capture_reference = capture_reference
    @responses, @operations, @snapshots, @quotes = {}, [], {}, {}
    @wallets = sources.group_by { |source| source.fetch(:descriptor).values_at("chain", "wallet_address") }.sort.to_h
  end

  def next_operation
    catch(:missing_input) do
      @wallets.each { |(chain, address), sources| @snapshots[[chain, address]] = wallet(chain, address, sources) }
      @sources.each { |source| @quotes[source[:external][:external_id]] = quotes_for(source) }
      nil
    end
  end

  def accept!(operation:, response:, fetched_at:)
    raise ArgumentError unless operation == next_operation && @operations.size < MAX_OPERATIONS
    timestamp = Time.iso8601(fetched_at)
    raise ArgumentError if timestamp < @observed_at || (@operations.last && timestamp < Time.iso8601(@operations.last.fetch("fetched_at")))
    key = Archive.digest(operation)
    raise ArgumentError if @responses.key?(key)
    row = { "operation" => operation, "response" => response, "fetched_at" => fetched_at }
    @responses[key] = row
    @operations << row
    raise Provider::AccountData::IncompletePage, "Wallet response chain exceeds its decoded budget" if JSON.generate(@operations).bytesize > Archive::MAX_BYTES
  end

  private
    def read(action, chain: nil, address: nil, **arguments)
      operation = { "action" => action, "chain" => chain, "address" => address, "arguments" => arguments.deep_stringify_keys }
      row = @responses[Archive.digest(operation)]
      throw :missing_input, operation unless row
      row.fetch("response")
    end

    def wallet(chain, address, sources)
      definition = @configuration.fetch("chains").fetch(chain)
      value = case definition.fetch("adapter")
      when "Onchain::BitcoinAdapter" then bitcoin(chain, address, definition)
      when "Onchain::EvmAdapter" then evm(chain, address, definition, sources)
      when "Onchain::SolanaAdapter" then solana(chain, address, definition, sources)
      else raise ArgumentError
      end
      rows = @operations.select { |row| row.dig("operation", "chain") == chain && row.dig("operation", "arguments", "wallet_address").to_s.in?([ "", address ]) && row.dig("operation", "address") == address }
      # Signature-source requests use token-account addresses, so bind the entire
      # chain's wallet inputs as well, not just calls addressed to the owner.
      rows = @operations.select { |row| row.dig("operation", "chain") == chain && row.dig("operation", "arguments", "wallet_address") == address } | rows
      snapshot = {
        "version" => 1, "chain" => chain, "wallet_address" => address, "observed_at" => @observed_at.getutc.iso8601(9),
        "assets" => unique(value.fetch(:assets), %w[kind contract]), "movements" => unique(value.fetch(:movements), %w[external_id contract]),
        "assets_truncated" => value.fetch(:assets_truncated), "history_truncated" => value.fetch(:history_truncated),
        "evidence" => { "capture_sha256" => Archive.digest(rows), "fetched_from" => rows.first&.fetch("fetched_at"),
          "fetched_through" => rows.last&.fetch("fetched_at"), "provenance" => "current_sync_physical_responses" }
      }
      Snapshot.new(snapshot)
    end

    def bitcoin(chain, address, definition)
      normalizer = Onchain::BitcoinAdapter.new
      canonical_address = normalizer.canonical_address(address)
      summary = read("bitcoin_summary", chain: chain, address: address)
      quantity = %w[chain_stats mempool_stats].sum do |key|
        stats = summary.fetch(key)
        integer(stats.fetch("funded_txo_sum")) - integer(stats.fetch("spent_txo_sum"))
      end / (10.to_d**8)
      rows, after, truncated = [], nil, false
      @configuration.fetch("history_pages").times do |index|
        page = read("bitcoin_history", chain: chain, address: address, after: after)
        rows.concat(page)
        truncated = page.size >= Provider::MempoolSpace::PAGE_SIZE
        break unless truncated
        after = page.last.fetch("txid")
        raise ArgumentError if rows[0...-page.size].any? { |row| row["txid"] == after }
      end
      movements = rows.filter_map do |row|
        received = row.fetch("vout").sum { |output| normalizer.canonical_address(output["scriptpubkey_address"]) == canonical_address ? integer(output.fetch("value")) : 0 }
        sent = row.fetch("vin").sum { |input| normalizer.canonical_address(input.dig("prevout", "scriptpubkey_address")) == canonical_address ? integer(input.fetch("prevout").fetch("value")) : 0 }
        amount = (received - sent).to_d / (10.to_d**8)
        next if amount.zero?
        # Pending Bitcoin observations have no chain date. Retain that absence;
        # a later day's factory must not redate them from the wall clock.
        movement(row.fetch("txid"), definition.dig("native", "symbol"), nil, amount, unix_date(row.dig("status", "block_time")))
      end
      { assets: [ native_asset(definition, quantity) ], movements: movements, assets_truncated: false, history_truncated: truncated }
    end

    def evm(chain, address, definition, sources)
      summary = read("evm", chain: chain, address: address, resource: "summary", cursor: nil).fetch("data")
      native = native_asset(definition, units(summary.fetch("coin_balance"), definition.dig("native", "decimals")))
      tokens, assets_truncated = evm_pages(chain, address, "token_balances", keyed: false)
      assets = tokens.filter_map do |row|
        token = row.fetch("token")
        next unless token["type"] == "ERC-20"
        contract = (token["address_hash"] || token["address"]).to_s.downcase
        raise ArgumentError if contract.empty?
        quantity = units(row.fetch("value"), token.fetch("decimals"))
        next if quantity.zero?
        symbol = token["symbol"].presence || "#{contract.first(6)}…#{contract.last(4)}"
        asset("erc20", symbol, token["name"].presence || symbol, token.fetch("decimals"), quantity, contract,
          token["exchange_rate"].present? && decimal(token["exchange_rate"]) * quantity >= 1)
          .merge("market_cap" => token["circulating_market_cap"].presence && decimal(token["circulating_market_cap"]))
      end.sort_by { |row| [ row["market_cap"] ? 0 : 1, -(row["market_cap"] || 0), row.fetch("contract") ] }
      tracked = sources.map { |source| source[:descriptor]["contract_address"] }.compact
      surfaced = assets.first(@configuration.fetch("asset_tokens")) | assets.select { |row| tracked.include?(row["contract"]) }
      assets_truncated ||= surfaced.size < assets.size
      keyed = @keyed_history && definition["etherscan_chain_id"].present?
      native_rows, native_truncated = evm_pages(chain, address, "native_transfers", keyed: keyed)
      token_rows, token_truncated = evm_pages(chain, address, "token_transfers", keyed: keyed)
      movements = native_rows.filter_map { |row| evm_movement(row, address, definition, token: false, keyed: keyed) } +
        token_rows.filter_map { |row| evm_movement(row, address, definition, token: true, keyed: keyed) }
      { assets: [ native, *surfaced.map { |row| row.except("market_cap") } ], movements: movements,
        assets_truncated: assets_truncated, history_truncated: native_truncated || token_truncated }
    end

    def evm_pages(chain, address, resource, keyed:)
      rows, cursor, truncated = [], nil, false
      seen = Set.new
      @configuration.fetch("history_pages").times do |index|
        if keyed
          result = read("etherscan", chain: chain, address: address, resource: resource, page: index + 1)
          rows.concat(result.fetch("rows"))
          truncated = !result.fetch("complete")
        else
          result = read("evm", chain: chain, address: address, resource: resource, cursor: cursor)
          body = result.fetch("data")
          rows.concat(body.is_a?(Array) ? body : body.fetch("items"))
          cursor = result["next_cursor"]
          truncated = cursor.present?
          raise ArgumentError if truncated && !seen.add?(Archive.digest(cursor))
        end
        raise Provider::AccountData::IncompletePage, "Wallet collection exceeds its row budget" if rows.size > Snapshot::MAX_MOVEMENTS
        break unless truncated
      end
      [ rows, truncated ]
    end

    def evm_movement(row, address, definition, token:, keyed:)
      if keyed
        from, to, raw = row.values_at("from", "to", "value")
        contract = token ? row.fetch("contractAddress").downcase : nil
        symbol = token ? row.fetch("tokenSymbol") : definition.dig("native", "symbol")
        decimals = token ? row.fetch("tokenDecimal") : definition.dig("native", "decimals")
        id = token ? [ row.fetch("hash"), row["logIndex"].presence || contract ].join("_") : row.fetch("hash")
        date = unix_date(row["timeStamp"])
      else
        from, to = row.dig("from", "hash"), row.dig("to", "hash")
        token_data = token ? row.fetch("token") : {}
        contract = token ? (token_data["address_hash"] || token_data.fetch("address")).downcase : nil
        symbol = token ? token_data.fetch("symbol") : definition.dig("native", "symbol")
        decimals = token ? (row.dig("total", "decimals") || token_data.fetch("decimals")) : definition.dig("native", "decimals")
        raw = token ? row.fetch("total").fetch("value") : row.fetch("value")
        id = token ? [ row.fetch("transaction_hash"), row["log_index"].nil? ? contract : row["log_index"] ].join("_") : row.fetch("hash")
        date = row["timestamp"].present? ? Time.iso8601(row["timestamp"]).in_time_zone(@timezone).to_date.iso8601 : nil
      end
      received, sent = to.to_s.downcase == address.downcase, from.to_s.downcase == address.downcase
      return if received == sent
      amount = units(raw, decimals) * (received ? 1 : -1)
      return if amount.zero?
      movement(id, symbol, contract, amount, date)
    end

    def solana(chain, address, definition, sources)
      balance = read("solana_balance", chain: chain, address: address)
      rows = Provider::SolanaRpc::TOKEN_PROGRAM_IDS.flat_map do |program|
        read("solana_tokens", chain: chain, address: address, program_id: program).fetch("value")
      end
      held = rows.filter_map do |row|
        info = row.fetch("account").fetch("data").fetch("parsed").fetch("info")
        raise ArgumentError unless info.fetch("owner") == address
        amount = info.fetch("tokenAmount")
        next if integer(amount.fetch("amount")).zero?
        { "pubkey" => row.fetch("pubkey"), "mint" => info.fetch("mint"), "amount" => amount.fetch("amount"), "decimals" => amount.fetch("decimals") }
      end
      raise ArgumentError unless held.map { |row| row["pubkey"] }.uniq.size == held.size
      mints = held.map { |row| row["mint"] }.uniq.sort
      tracked = sources.map { |source| source[:descriptor]["contract_address"] }.compact
      selected = mints.first(@configuration.fetch("asset_tokens")) | (mints & tracked)
      accounts = held.select { |row| selected.include?(row["mint"]) }
      metadata = Onchain::SolanaAdapter::KNOWN_MINTS.transform_values { |value| value.stringify_keys }
      # A fully spent selected token still needs verified mint metadata for its
      # historical movements; copied display text is not a pricing identity.
      ((selected | tracked) - metadata.keys).each_slice(Provider::JupiterTokens::BATCH_SIZE) do |batch|
        values = read("token_metadata", chain: chain, address: address, mints: batch)
        values.each do |value|
          next unless batch.include?(value["id"]) && value["isVerified"] == true && value["symbol"].present?
          candidate = { "symbol" => value.fetch("symbol"), "name" => value["name"].presence || value.fetch("symbol") }
          raise ArgumentError if metadata[value["id"]] && metadata[value["id"]] != candidate
          metadata[value["id"]] = candidate
        end
      end
      assets = accounts.group_by { |row| row["mint"] }.map do |mint, group|
        raise ArgumentError unless group.map { |row| integer(row["decimals"]) }.uniq.one?
        meta = mint_metadata(metadata, mint)
        quantity = group.sum { |row| units(row["amount"], row["decimals"]) }
        asset("spl", meta.fetch("symbol"), meta.fetch("name"), group.first.fetch("decimals"), quantity, mint, metadata.key?(mint))
      end
      (tracked - mints).each do |mint|
        meta = mint_metadata(metadata, mint)
        descriptor = sources.find { |source| source[:descriptor]["contract_address"] == mint }.fetch(:descriptor)
        assets << asset("spl", meta.fetch("symbol"), meta.fetch("name"), descriptor.fetch("decimals"), 0.to_d, mint, metadata.key?(mint))
      end
      signature_sources = [ address, *accounts.sort_by { |row| [ -integer(row["amount"]), row["pubkey"] ] }
        .first(Onchain::SolanaAdapter::MAX_TOKEN_ACCOUNTS_FOR_HISTORY).map { |row| row.fetch("pubkey") } ].uniq
      pages = signature_sources.map do |pubkey|
        read("solana_signatures", chain: chain, address: pubkey, wallet_address: address)
      end
      signatures = signature_observations(pages.flatten).sort_by { |row| [ -row["blockTime"].to_i, row.fetch("signature") ] }
      limit = @configuration.fetch("history_transactions")
      omitted_sources = held.map { |row| row.fetch("pubkey") } - signature_sources
      truncated = omitted_sources.any? || pages.any? { |page| page.size >= Onchain::SolanaAdapter::SIGNATURES_PER_SOURCE } || signatures.size > limit
      movements = signatures.first(limit).flat_map do |entry|
        transaction = read("solana_transaction", chain: chain, address: address, signature: entry.fetch("signature"))
        if transaction.nil?
          truncated = true
          next []
        end
        solana_movements(transaction, entry, address, definition, metadata)
      end
      { assets: [ native_asset(definition, units(balance.fetch("value"), definition.dig("native", "decimals"))), *assets ], movements: movements,
        assets_truncated: selected.size < mints.size, history_truncated: truncated }
    end

    def solana_movements(transaction, entry, address, definition, metadata)
      meta = transaction.fetch("meta")
      return [] unless meta["err"].nil?
      date = unix_date(entry["blockTime"] || transaction["blockTime"])
      signature = entry.fetch("signature")
      rows = []
      keys = transaction.fetch("transaction").fetch("message").fetch("accountKeys")
      index = keys.index { |key| (key.is_a?(Hash) ? key["pubkey"] : key) == address }
      if index
        amount = (integer(meta.fetch("postBalances").fetch(index)) - integer(meta.fetch("preBalances").fetch(index))).to_d / (10.to_d**9)
        rows << movement(signature, definition.dig("native", "symbol"), nil, amount, date) if amount.abs > Onchain::SolanaAdapter::FEE_DUST
      end
      before = solana_token_balances(meta.fetch("preTokenBalances", []), address)
      after = solana_token_balances(meta.fetch("postTokenBalances", []), address)
      (before.keys | after.keys).each do |mint|
        amount = after.fetch(mint, 0.to_d) - before.fetch(mint, 0.to_d)
        rows << movement("#{signature}_#{mint}", mint_metadata(metadata, mint).fetch("symbol"), mint, amount, date) unless amount.zero?
      end
      rows
    end

    def signature_observations(rows)
      rows.group_by { |row| row.fetch("signature") }.map do |signature, group|
        # Confirmation status may advance between wallet/token-account reads.
        # A later response may fill a previously unknown timestamp. Preserve all
        # raw observations, while requiring stable slot/time/error agreement.
        %w[slot blockTime].each do |key|
          values = group.filter_map { |row| row[key] }.map { |value| integer(value) }.uniq
          raise ArgumentError unless values.size <= 1
        end
        errors = group.select { |row| row.key?("err") }.map { |row| row["err"] }.uniq
        raise ArgumentError unless errors.size <= 1
        { "signature" => signature, "blockTime" => group.filter_map { |row| row["blockTime"] }.first }
      end
    end

    def solana_token_balances(rows, address)
      rows.select { |row| row["owner"] == address }.group_by { |row| row.fetch("mint") }.transform_values do |group|
        group.sum { |row| units(row.fetch("uiTokenAmount").fetch("amount"), row.fetch("uiTokenAmount").fetch("decimals")) }
      end
    end

    def mint_metadata(metadata, mint)
      metadata[mint] || { "symbol" => "SPL:#{mint.first(4)}…#{mint.last(4)}", "name" => "SPL token #{mint}" }
    end

    def quotes_for(source)
      descriptor = source.fetch(:descriptor)
      snapshot = @snapshots.fetch(descriptor.values_at("chain", "wallet_address"))
      asset = snapshot.asset_for(descriptor)
      symbol = Onchain::AssetSymbol.canonical(asset ? asset.fetch("symbol") : descriptor.fetch("symbol"))
      ticker = Onchain::SecurityResolver::SYMBOL_PATTERN.match?(symbol) ? "CRYPTO:#{symbol}" : nil
      current_date = @observed_at.in_time_zone(@timezone).to_date
      dates = snapshot.movements_for(descriptor).filter_map { |row| row["date"] }.uniq.sort
        .select { |date| !@sync_start_date || Date.iso8601(date) >= @sync_start_date }
      raise ArgumentError if dates.any? { |date| Date.iso8601(date) > current_date }
      currency = source[:external].fetch(:currency).upcase
      converted = if ticker
        (dates | [ current_date.iso8601 ]).to_h do |date|
          raw = read("price", ticker: ticker, date: date)
          quote = price_value(raw, date)
          if quote && quote.fetch("original_currency") != currency
            fx = read("fx", from: quote.fetch("original_currency"), to: currency, date: date)
            unless fx
              fx = Provider::AccountData::OnchainWallet::FxAcquisition.new(options: @configuration.fetch("fx"),
                from: quote.fetch("original_currency"), to: currency, date: Date.iso8601(date), read: method(:read), reference: @capture_reference).call
            end
            if fx
              rate = decimal(fx.fetch("rate"))
              raise ArgumentError unless rate.positive? && Date.iso8601(fx.fetch("date")) <= Date.iso8601(date)
              quote = quote.merge("price" => (decimal(quote.fetch("original_price")) * rate).to_s("F"), "fx_rate" => rate.to_s("F"), "fx_date" => fx.fetch("date"))
            else
              quote = nil
            end
          end
          [ date, quote ]
        end
      else
        {}
      end
      payload = { "version" => 1, "snapshot_sha256" => snapshot.fingerprint, "observed_at" => @observed_at.getutc.iso8601(9),
        "external_id" => source[:external].fetch(:external_id), "ticker" => ticker, "currency" => currency,
        "current" => converted[current_date.iso8601], "historical" => converted.slice(*dates).compact }
      Provider::AccountData::OnchainWallet::Quotes.new(payload, snapshot: snapshot, currency: currency,
        observed_at: @observed_at.in_time_zone(@timezone), external_id: source[:external].fetch(:external_id), ticker: ticker).evidence
    end

    def price_value(raw, date)
      return nil if raw["policy"] == "disabled" || raw["rows"] == []
      if raw["policy"] == "binance_public_stablecoin_usd_one/v1"
        raise ArgumentError unless raw["currency"] == "USD" && raw["price"] == "1" && raw["date"] == date
        price = BigDecimal("1")
      else
        raise ArgumentError unless raw["policy"] == "binance_public_daily_close/v1" && raw.fetch("rows").one?
        row = raw.fetch("rows").sole
        raise ArgumentError unless Time.at(integer(row.fetch(0)) / 1000).utc.to_date.iso8601 == date
        price = decimal(row.fetch(4))
        return nil unless price.positive?
      end
      { "date" => date, "price" => price.to_s("F"), "original_price" => price.to_s("F"),
        "original_currency" => raw.fetch("currency"), "fx_rate" => nil, "fx_date" => nil }
    end

    def native_asset(definition, quantity)
      meta = definition.fetch("native")
      asset("native", meta.fetch("symbol"), meta.fetch("name"), meta.fetch("decimals"), quantity, nil, true)
    end

    def asset(kind, symbol, name, decimals, quantity, contract, notable)
      { "kind" => kind, "symbol" => symbol, "name" => name, "decimals" => integer(decimals), "quantity" => quantity.to_s("F"),
        "contract" => contract, "notable" => !!notable }
    end

    def movement(id, symbol, contract, quantity, date)
      { "external_id" => id, "symbol" => symbol, "contract" => contract, "amount" => quantity.to_s("F"), "date" => date }
    end

    def integer(value)
      raise ArgumentError unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d+\z/))
      number = Integer(value, 10) if value.is_a?(String)
      number ||= value
      raise ArgumentError if number.negative?
      number
    end

    def units(value, decimals)
      digits = integer(decimals)
      raise ArgumentError unless digits.between?(0, 255)
      integer(value).to_d / (10.to_d**digits)
    end

    def decimal(value)
      Snapshot.decimal(value)
    end

    def unix_date(value)
      value.nil? || value == "" ? nil : Time.at(integer(value)).in_time_zone(@timezone).to_date.iso8601
    end

    def unique(rows, keys)
      rows.group_by { |row| row.values_at(*keys) }.map do |_key, group|
        raise ArgumentError unless group.uniq.one?
        group.first
      end
    end
end
