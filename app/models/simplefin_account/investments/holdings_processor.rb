class SimplefinAccount::Investments::HoldingsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    payload = holdings_data
    return if payload.empty?
    return unless [ "Investment", "Crypto" ].include?(account&.accountable_type)

    # SimpleFIN reports one record per LOT, so a single position can arrive as
    # several records sharing a security -- a 401k that splits employee deferral
    # from employer match is the common case. `holdings` is uniquely indexed on
    # (account_id, security_id, date, currency), so importing lots one at a time
    # makes each overwrite the last and the account silently loses the value of
    # every lot but one. Combine them into the position they represent first.
    positions = {}
    # Records this payload could not read or save. Only a payload read in
    # full can say a position is gone.
    not_imported = []
    snapshot_date = Date.current

    payload.each do |simplefin_holding|
      begin
        symbol = simplefin_holding["symbol"].presence
        holding_id = simplefin_holding["id"]
        description = simplefin_holding["description"].to_s.strip

        Rails.logger.debug({ event: "simplefin.holding.start", sfa_id: simplefin_account.id, account_id: account&.id, id: holding_id, symbol: symbol, raw: simplefin_holding }.to_json)

        unless holding_id.present?
          not_imported << { reason: "missing_id", symbol: symbol }
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
          not_imported << { reason: "no_symbol_or_description", id: holding_id }
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "no_symbol_or_description", id: holding_id }.to_json)
          next
        end

        security = resolve_security(symbol, simplefin_holding["description"])
        unless security.present?
          not_imported << { reason: "unresolved_security", id: holding_id, symbol: symbol }
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "unresolved_security", id: holding_id, symbol: symbol }.to_json)
          next
        end

        # Parse provider data with robust fallbacks across SimpleFin sources
        # NOTE: "value" is intentionally excluded from the market_value fallback chain
        # because some brokerages (e.g. Vanguard, Fidelity) use "value" to mean cost basis,
        # which would cause the system to display average cost as current price. (GH #1182)
        qty = parse_decimal(any_of(simplefin_holding, %w[shares quantity qty units]))
        market_value = parse_decimal(any_of(simplefin_holding, %w[market_value current_value]))
        fallback_price = parse_decimal(any_of(simplefin_holding, %w[purchase_price price unit_price average_cost avg_cost]))

        # A number that is present but unreadable is not a zero. Reading it as
        # one would make the record look like an empty position below, and the
        # purge would drop the position's earlier row for the day. A price only
        # matters when there is no market value to derive it from.
        malformed = []
        malformed << "quantity" if qty.nil?
        malformed << "market_value" if market_value.nil?
        malformed << "price" if malformed.empty? && fallback_price.nil? && qty.positive? && !market_value.positive?
        if malformed.any?
          not_imported << { reason: "malformed_number", fields: malformed, id: holding_id, symbol: symbol }
          Rails.logger.debug({ event: "simplefin.holding.skip", reason: "malformed_number", fields: malformed, id: holding_id, symbol: symbol }.to_json)
          next
        end

        raw_cost_basis, cost_basis_source_key = cost_basis_from(simplefin_holding)
        cost_basis = normalize_cost_basis(raw_cost_basis, qty, cost_basis_source_key, institution_reports_total_basis?)

        # Derive price from market_value when possible; otherwise fall back to any price field
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
        holding_date = snapshot_date

        # Skip zero positions with no value to avoid invisible rows. The record
        # was read, so a same-day row it had earlier is still purged.
        next if qty.to_d.zero? && computed_amount.to_d.zero?

        currency = simplefin_holding["currency"].presence || "USD"
        position = positions[[ security.id, currency, holding_date ]] ||= {
          security: security,
          currency: currency,
          date: holding_date,
          qty: 0.to_d,
          amount: 0.to_d,
          # cost_basis is stored PER SHARE, so lots combine into a
          # share-weighted average rather than a sum. That average is only
          # meaningful if EVERY lot reported one -- see basis_complete.
          basis_value: 0.to_d,
          basis_qty: 0.to_d,
          basis_complete: true,
          fallback_price: nil,
          external_ids: []
        }

        position[:qty] += qty.to_d
        position[:amount] += computed_amount.to_d
        position[:external_ids] << "simplefin_#{holding_id}_#{holding_date}"
        position[:fallback_price] ||= price if price.to_d.positive?

        if qty.to_d.positive?
          if cost_basis.present?
            position[:basis_value] += cost_basis.to_d * qty.to_d
            position[:basis_qty] += qty.to_d
          else
            # Averaging over only the lots that reported a basis would apply
            # that figure to shares whose cost is genuinely unknown, inventing
            # cost and therefore inventing gain/loss. Unknown has to stay
            # unknown for the whole position.
            position[:basis_complete] = false
          end
        end
      rescue => e
        not_imported << { reason: "error", id: holding_id, symbol: symbol, error: "#{e.class}: #{e.message}" }
        ctx = (defined?(symbol) && symbol.present?) ? " #{symbol}" : ""
        Rails.logger.error "Error processing SimpleFin holding#{ctx}: #{e.message}"
      end
    end

    saved_holding_ids = []
    current = while_payload_current(payload) do
      positions.each_value do |position|
        saved_holding_ids << import_position(position).id
      rescue => e
        not_imported << { reason: "import_failed", symbol: position[:security]&.ticker, error: "#{e.class}: #{e.message}" }
        Rails.logger.error "Error importing SimpleFin position #{position[:security]&.ticker}: #{e.message}"
      end

      purge_unreported_holdings(snapshot_date, saved_holding_ids) if not_imported.empty?
    end
    return unless current

    report_incomplete_payload(snapshot_date, not_imported) if not_imported.any?
  end

  private
    attr_reader :simplefin_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      simplefin_account.current_account
    end

    # Saves one combined position. The savepoint keeps a failed save from
    # aborting the surrounding transaction, so the other positions still save.
    def import_position(position)
      qty = position[:qty]
      amount = position[:amount]

      price = if qty.positive? && amount.positive?
        amount / qty
      else
        position[:fallback_price] || 0
      end

      cost_basis = if position[:basis_complete] && position[:basis_qty].positive?
        position[:basis_value] / position[:basis_qty]
      end

      # Sorted so the identifier stays stable across syncs when a provider
      # reorders lots. If the chosen lot later disappears, import_holding falls
      # back to matching on security/date/currency and updates the same row.
      external_id = position[:external_ids].sort.first

      saved = SimplefinAccount.transaction(requires_new: true) do
        import_adapter.import_holding(
          security: position[:security],
          quantity: qty,
          amount: amount,
          currency: position[:currency],
          date: position[:date],
          price: price,
          cost_basis: cost_basis,
          external_id: external_id,
          account_provider_id: simplefin_account.account_provider&.id,
          source: "simplefin",
          delete_future_holdings: false  # SimpleFin tracks each holding uniquely
        )
      end

      Rails.logger.debug({ event: "simplefin.holding.saved", account_id: account&.id, holding_id: saved.id, security_id: saved.security_id, qty: saved.qty.to_s, amount: saved.amount.to_s, currency: saved.currency, date: saved.date, external_id: saved.external_id, lots: position[:external_ids].size }.to_json)

      saved
    end

    # SimplefinHoldingsApplyJob and the sync's own account processing can run
    # this for the same account at the same time, and a sync that lands
    # mid-run stores a newer payload. A run still working from the older
    # payload must neither save its positions over the newer run's rows nor
    # purge against them. So the saves and the purge run in one transaction
    # that holds the simplefin_accounts row lock, and only if the stored
    # payload is still the one this run read; otherwise the run stops and
    # leaves the day to the newer payload's run. An import storing a newer
    # payload updates the same row, so it waits until this commits.
    #
    # Security resolution runs before this, outside the lock, because it can
    # call out to a market data provider. An account linked only through the
    # legacy account foreign key has no account provider, so nothing is
    # purged and its saves run unguarded, as before.
    def while_payload_current(payload)
      unless simplefin_account.account_provider
        yield
        return true
      end

      SimplefinAccount.transaction do
        stored = SimplefinAccount.lock.where(id: simplefin_account.id).pick(:raw_holdings_payload) || []
        unless stored.as_json == payload.as_json
          Rails.logger.info("SimpleFin: holdings payload for account #{account.id} changed during processing; leaving its holdings to the newer run")
          next false
        end

        yield
        true
      end
    end

    # A position an earlier sync reported today, but this payload no longer
    # has -- sold since, or a sweep fund that settled -- would otherwise keep
    # its row for the day, and the balance history counts it.
    def purge_unreported_holdings(snapshot_date, saved_holding_ids)
      account_provider_id = simplefin_account.account_provider&.id
      return unless account_provider_id

      deleted = account.holdings
        .where(account_provider_id: account_provider_id, date: snapshot_date)
        .where.not(id: saved_holding_ids)
        .delete_all

      Rails.logger.info("SimpleFin: removed #{deleted} holding(s) for #{snapshot_date} no longer reported on account #{account.id}") if deleted > 0
    end

    def report_incomplete_payload(snapshot_date, not_imported)
      Rails.logger.warn("SimpleFin: #{not_imported.size} holding record(s) not imported for account #{account.id}; keeping #{snapshot_date} holdings the payload did not report")

      DebugLogEntry.capture(
        category: "provider_sync_warning",
        level: "warn",
        message: "SimpleFIN holdings payload not fully imported; kept #{snapshot_date} holdings it did not report",
        source: self.class.name,
        provider_key: "simplefin",
        account: account,
        account_provider: simplefin_account.account_provider,
        metadata: {
          simplefin_account_id: simplefin_account.id,
          snapshot_date: snapshot_date,
          not_imported_count: not_imported.size,
          not_imported: not_imported.first(20)
        }
      )
    end

    def holdings_data
      # Use the dedicated raw_holdings_payload field
      simplefin_account.raw_holdings_payload || []
    end

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
    # Exception: a small allowlist of brokerages (Vanguard, Fidelity, Schwab)
    # is known to populate cost_basis with the total position cost in
    # violation of the spec (#1718, #1182, #2626). For those connections
    # only, divide by qty.
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
    TOTAL_BASIS_INSTITUTIONS = %w[vanguard fidelity schwab etrade e*trade].freeze

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

    # Blank is zero. A value that is present but is not a finite number
    # returns nil, so a caller can tell "reported zero" from "unreadable".
    def parse_decimal(value)
      return 0 unless value.present?

      number = case value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      end

      return number if number&.finite?

      Rails.logger.error "Failed to parse SimpleFin decimal value #{value.inspect}"
      nil
    rescue ArgumentError, TypeError => e
      Rails.logger.error "Failed to parse SimpleFin decimal value #{value.inspect}: #{e.message}"
      nil
    end
end
