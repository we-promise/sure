class SimplefinAccount::Investments::HoldingsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return if holdings_data.empty?
    return unless [ "Investment", "Crypto" ].include?(account&.accountable_type)

    holdings_data.each do |simplefin_holding|
      begin
        symbol = simplefin_holding["symbol"].presence
        holding_id = simplefin_holding["id"]
        description = simplefin_holding["description"].to_s.strip

        Rails.logger.debug({ event: "simplefin.holding.start", sfa_id: simplefin_account.id, account_id: account&.id, id: holding_id, symbol: symbol, raw: simplefin_holding }.to_json)

        unless holding_id.present?
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "missing_id", id: holding_id, symbol: symbol }.to_json)
          next
        end

        # If symbol is missing but we have a description, create a synthetic ticker
        # This allows tracking holdings like 401k funds that don't have standard symbols
        # Append a hash suffix to ensure uniqueness for similar descriptions
        if symbol.blank? && description.present?
          normalized = description.gsub(/[^a-zA-Z0-9]/, "_").upcase.truncate(24, omission: "")
          hash_suffix = Digest::MD5.hexdigest(description)[0..4].upcase
          symbol = "CUSTOM:#{normalized}_#{hash_suffix}"
          Rails.logger.info("SimpleFin: using synthetic ticker #{symbol} for holding #{holding_id} (#{description})")
        end

        unless symbol.present?
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "no_symbol_or_description", id: holding_id }.to_json)
          next
        end

        security = resolve_security(symbol, simplefin_holding["description"])
        unless security.present?
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "unresolved_security", id: holding_id, symbol: symbol }.to_json)
          next
        end

        # Parse provider data with robust fallbacks across SimpleFin sources
        # NOTE: "value" is intentionally excluded from the market_value fallback chain
        # because some brokerages (e.g. Vanguard, Fidelity) use "value" to mean cost basis,
        # which would cause the system to display average cost as current price. (GH #1182)
        qty = parse_decimal(any_of(simplefin_holding, %w[shares quantity qty units]))
        market_value = parse_decimal(any_of(simplefin_holding, %w[market_value current_value]))
        raw_cost_basis, cost_basis_source_key = cost_basis_from(simplefin_holding)
        cost_basis = normalize_cost_basis(raw_cost_basis, qty, cost_basis_source_key, institution_reports_total_basis?)

        # Derive price from market_value when possible; otherwise fall back to any price field
        fallback_price = parse_decimal(any_of(simplefin_holding, %w[purchase_price price unit_price average_cost avg_cost]))
        price = if qty > 0 && market_value > 0
          market_value / qty
        else
          fallback_price || 0
        end

        # Compute an amount we can persist (some providers omit market_value)
        computed_amount = if market_value > 0
          market_value
        elsif qty > 0 && price > 0
          qty * price
        else
          0
        end

        # SimpleFIN holdings represent a current snapshot, not historical positions.
        # Always use today's date regardless of the `created` timestamp (which is when
        # the holding was first seen by SimpleFIN, not when we observed it).
        holding_date = Date.current

        # Skip zero positions with no value to avoid invisible rows
        next if qty.to_d.zero? && computed_amount.to_d.zero?

        saved = import_adapter.import_holding(
          security: security,
          quantity: qty,
          amount: computed_amount,
          currency: simplefin_holding["currency"].presence || "USD",
          date: holding_date,
          price: price,
          cost_basis: cost_basis,
          external_id: "simplefin_#{holding_id}",
          account_provider_id: simplefin_account.account_provider&.id,
          source: "simplefin",
          delete_future_holdings: false  # SimpleFin tracks each holding uniquely
        )

        Rails.logger.debug({ event: "simplefin.holding.saved", account_id: account&.id, holding_id: saved.id, security_id: saved.security_id, qty: saved.qty.to_s, amount: saved.amount.to_s, currency: saved.currency, date: saved.date, external_id: saved.external_id }.to_json)
      rescue => e
        ctx = (defined?(symbol) && symbol.present?) ? " #{symbol}" : ""
        Rails.logger.error "Error processing SimpleFin holding#{ctx}: #{e.message}"
      end
    end
  end

  private
    attr_reader :simplefin_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      simplefin_account.current_account
    end

    # Loads the raw holdings payload and collapses multiple lots that share the
    # same symbol into a single aggregated holding. Lots without a symbol are
    # passed through individually unchanged.
    def holdings_data
      raw = simplefin_account.raw_holdings_payload || []
      return raw if raw.empty?

      grouped = raw
        .select { |h| h.is_a?(Hash) }
        .group_by { |h| aggregation_key(h) }

      grouped.flat_map do |key, lots|
        next lots if key.start_with?("__nosym_")
        [ normalize_to_aggregate(key, lots) ]
      end
    end

    # Returns a grouping key for a raw holding hash. Holdings with a symbol are
    # keyed by the upcased symbol and currency (e.g. "AAPL-USD") so that
    # same-ticker, different-currency positions are never merged. Holdings
    # without a symbol get a unique key prefixed with "__nosym_" to ensure they
    # are always kept as individual records.
    def aggregation_key(holding)
      sym = holding["symbol"].to_s.upcase.strip.presence
      return "__nosym_#{holding['id']}" unless sym

      currency = holding["currency"].to_s.upcase.presence || "UNKNOWN"
      "#{sym}-#{currency}"
    end

    # Merges one or more lots for the same symbol into a single canonical holding
    # hash. Quantities and market values are summed; cost basis is computed as a
    # weighted average via `weighted_average_cost_basis`. The merged record is
    # assigned a stable synthetic id of the form "HOL-{SYMBOL-CURRENCY}", and all
    # quantity/value field aliases are removed in favour of the canonical
    # `shares` and `market_value` keys.
    def normalize_to_aggregate(key, lots)
      first = lots.first
      symbol = first["symbol"].to_s.strip.upcase

      qty_keys   = %w[shares quantity qty units]
      value_keys = %w[market_value current_value]

      total_qty   = lots.sum { |l| parse_decimal(any_of(l, qty_keys)) }
      total_value = lots.sum { |l| parse_decimal(any_of(l, value_keys)) }
      cost_basis  = weighted_average_cost_basis(lots, qty_keys)

      merged = first.dup
      merged["id"] = "HOL-#{key}"
      merged["symbol"] = symbol

      qty_keys.each   { |k| merged.delete(k) }
      value_keys.each { |k| merged.delete(k) }
      merged["shares"]       = total_qty.to_s
      merged["market_value"] = total_value.to_s

      %w[cost_basis basis total_cost value].each { |k| merged.delete(k) }
      if cost_basis
        stored_basis = institution_reports_total_basis? ? cost_basis * total_qty : cost_basis
        merged["cost_basis"] = stored_basis.to_s
      end

      Rails.logger.debug("SimpleFIN: normalized #{lots.size} #{'lot'.pluralize(lots.size)} for #{symbol}")

      merged
    end

    # Computes the weighted average per-share cost basis across a collection of
    # lots. Each lot's contribution is weighted by its quantity. Whether a basis
    # value represents a per-share or total-position cost is determined by the
    # source key and the `institution_reports_total_basis?` flag — lots sourced
    # from `total_cost` or `value` are always treated as totals, while
    # `cost_basis`/`basis` are treated as totals only for allowlisted
    # institutions. Lots with no recognisable basis key or zero quantity are skipped.
    def weighted_average_cost_basis(lots, qty_keys)
      total_basis = 0
      total_qty_with_basis = 0
      any_basis_present = false

      lots.each do |l|
        raw_basis_value, source_key = cost_basis_from(l)
        next if raw_basis_value.nil?

        lot_qty = parse_decimal(any_of(l, qty_keys))
        next unless lot_qty.positive?

        any_basis_present = true

        is_total = %w[total_cost value].include?(source_key) ||
                   (institution_reports_total_basis? && %w[cost_basis basis].include?(source_key))

        lot_total = is_total ? raw_basis_value : raw_basis_value * lot_qty
        total_basis += lot_total
        total_qty_with_basis += lot_qty
      end

      return nil unless any_basis_present
      return nil unless total_qty_with_basis.positive?

      total_basis / total_qty_with_basis
    end

    # Extracts the first available cost basis value from a SimpleFIN holding payload.
    # For each key, blank or empty values are ignored. The first non-empty
    # value found is parsed into a decimal using `parse_decimal` and returned
    # along with the matching source key.
    def cost_basis_from(simplefin_holding)
      %w[cost_basis basis total_cost value].each do |key|
        raw = simplefin_holding[key]
        next if raw.nil? || raw.to_s.strip.empty?

        return [ parse_decimal(raw), key ]
      end

      [ nil, nil ]
    end

    # Sure stores holding cost_basis as per-share average cost. SimpleFIN
    # brokerages are inconsistent about which field carries which shape:
    #
    #   - total_cost / value: always a total position cost per the SimpleFIN
    #     spec and observed payloads; divide by qty unconditionally.
    #   - cost_basis / basis: the spec calls this per-share, and most
    #     brokerages comply. Keep these values unchanged by default.
    #
    # Exception: a small allowlist of brokerages (Vanguard, Fidelity) is
    # known to populate cost_basis with the total position cost in violation
    # of the spec (#1718, #1182). For those connections only, divide by qty.
    #
    # An earlier revision of this fix used a magnitude heuristic
    # (share_price × √qty midpoint). It was withdrawn because a legitimate
    # per-share basis on a holding with a large unrealized loss
    # (e.g. 100 shares with basis $100 now worth $5) trips the midpoint and
    # gets mis-divided to $1/share — corrupting compliant providers. The
    # allowlist trades some manual maintenance for that safety.
    def normalize_cost_basis(raw_cost_basis, qty, source_key, total_basis_institution = false)
      return nil if raw_cost_basis.nil?

      if %w[total_cost value].include?(source_key) ||
         (total_basis_institution && %w[cost_basis basis].include?(source_key))
        return nil unless qty.to_d.positive?
        return raw_cost_basis / qty
      end

      raw_cost_basis
    end

    # Institutions known to populate the SimpleFIN `cost_basis` / `basis`
    # field with the total position cost rather than the per-share value the
    # spec requires. Matched as case-insensitive substrings against the
    # account's stored org name and domain.
    TOTAL_BASIS_INSTITUTIONS = %w[vanguard fidelity].freeze

    def institution_reports_total_basis?
      org = simplefin_account.respond_to?(:org_data) ? simplefin_account.org_data : nil
      return false if org.blank?

      candidates = [ org["name"], org[:name], org["domain"], org[:domain] ].compact.map(&:to_s).map(&:downcase)
      return false if candidates.empty?

      TOTAL_BASIS_INSTITUTIONS.any? { |needle| candidates.any? { |c| c.include?(needle) } }
    end

    def resolve_security(symbol, description)
      # Normalize crypto tickers to a distinct namespace so they don't collide with equities
      sym = symbol.to_s.upcase
      is_crypto_account = account&.accountable_type == "Crypto" || simplefin_account.name.to_s.downcase.include?("crypto")
      is_crypto_symbol  = %w[BTC ETH SOL DOGE LTC BCH].include?(sym)
      mentions_crypto   = description.to_s.downcase.include?("crypto")

      if !sym.include?(":") && (is_crypto_account || is_crypto_symbol || mentions_crypto)
        sym = "CRYPTO:#{sym}"
      end

      # Custom tickers (from holdings without symbols) should always be offline
      is_custom = sym.start_with?("CUSTOM:")

      # Use Security::Resolver to find or create the security, but be resilient
      begin
        if is_custom
          # Skip resolver for custom tickers - create offline security directly
          raise "Custom ticker - skipping resolver"
        end
        Security::Resolver.new(sym).resolve
      rescue => e
        # If provider search fails or any unexpected error occurs, fall back to an offline security
        Rails.logger.warn "SimpleFin: resolver failed for symbol=#{sym}: #{e.class} - #{e.message}; falling back to offline security" unless is_custom
        Security.find_or_initialize_by(ticker: sym).tap do |sec|
          sec.offline = true if sec.respond_to?(:offline) && sec.offline != true
          sec.name = description.presence if sec.name.blank? && description.present?
          sec.save! if sec.changed?
        end
      end
    end

    def parse_holding_date(created_timestamp)
      return nil unless created_timestamp

      case created_timestamp
      when Integer
        Time.at(created_timestamp).to_date
      when String
        Date.parse(created_timestamp)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin holding date #{created_timestamp}: #{e.message}"
      nil
    end

    # Returns the first non-empty value for any of the provided keys in the given hash
    def any_of(hash, keys)
      return nil unless hash.respond_to?(:[])
      Array(keys).each do |k|
        # Support symbol or string keys
        v = hash[k]
        v = hash[k.to_s] if v.nil?
        v = hash[k.to_sym] if v.nil?
        return v if !v.nil? && v.to_s.strip != ""
      end
      nil
    end

    def parse_decimal(value)
      return 0 unless value.present?

      case value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        BigDecimal("0")
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin decimal value #{value}: #{e.message}"
      BigDecimal("0")
    end
end
