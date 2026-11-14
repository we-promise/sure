class SnaptradeAccount::HoldingsProcessor
  include SnaptradeAccount::DataHelpers

  def initialize(snaptrade_account)
    @snaptrade_account = snaptrade_account
  end

  def process
    return unless account.present?

    holdings_data = @snaptrade_account.raw_holdings_payload
    failed = false

    if holdings_data.present?
      Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Processing #{holdings_data.size} holdings"

      # Log sample of first holding to understand structure
      if holdings_data.first
        sample = holdings_data.first
        Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Sample holding keys: #{sample.keys.first(10).join(', ')}"
        if sample["symbol"] || sample[:symbol]
          symbol_sample = sample["symbol"] || sample[:symbol]
          Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Symbol data keys: #{symbol_sample.keys.first(10).join(', ')}" if symbol_sample.is_a?(Hash)
        end
      end

      holdings_data.each_with_index do |holding_data, idx|
        Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Processing holding #{idx + 1}/#{holdings_data.size}"
        failed = true unless process_holding(holding_data.with_indifferent_access)
      rescue => e
        failed = true
        Rails.logger.error "SnaptradeAccount::HoldingsProcessor - Failed to process holding #{idx + 1}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
      end
    end

    # A row that failed or was skipped must not read as a closed position, nor a
    # list this sync didn't fetch, nor an empty list SnapTrade's own total contradicts.
    if !failed && @snaptrade_account.last_holdings_sync&.after?(1.hour.ago)
      holdings_data.blank? && positions_in_total? ? capture_kept_empty_snapshot : zero_vanished_positions
    end

    # Always run, even with no security holdings — secondary-currency cash
    # should still be surfaced (issue #1809).
    process_cash_holdings
  end

  private

    # The latest provider snapshot is the account's current holdings, so a
    # position the broker no longer reports (closed, expired) would stay
    # current forever. Write it a zero row today instead.
    def zero_vanished_positions
      provider_id = @snaptrade_account.account_provider&.id
      vanished_positions.find_each do |h|
        security = h.provider_security || h.security
        # The adapter matches a row without external_id by security, date and
        # currency alone, so never zero another provider's row for today. Rows without a
        # provider are Sure's own materialized ones, which the sync rewrites anyway.
        next if account.holdings.where(security: security, date: Date.current, currency: h.currency)
          .where.not(account_provider_id: [ nil, provider_id ]).exists?

        import_adapter.import_holding(security: security, quantity: 0, amount: 0, currency: h.currency,
          date: Date.current, price: h.price, account_provider_id: provider_id, source: "snaptrade", delete_future_holdings: false)
      end
    end

    def vanished_positions
      provider_id = @snaptrade_account.account_provider&.id or return Holding.none
      scope = account.holdings.where(account_provider_id: provider_id, external_id: nil)
      scope.where(date: scope.maximum(:date)).where.not(qty: 0).where.not(security_id: @imported.to_a)
    end

    def capture_kept_empty_snapshot
      # holdings_unavailable accounts always report an empty list; only log a surprising one.
      return if @snaptrade_account.institution_metadata&.dig("sync_status", "holdings", "holdings_unavailable")
      return unless vanished_positions.exists?

      Rails.logger.warn("SnapTrade: kept positions for account #{account.id}: the positions list is empty but the account total still reports holdings")
    end

    # Non-cash value in the account total (or no total) means positions exist --
    # for a few days only: value SnapTrade can't list (filtered futures,
    # unsupported assets, cash in other currencies) must not pin a sold position.
    def positions_in_total?
      return true if @snaptrade_account.institution_metadata&.dig("sync_status", "holdings", "holdings_unavailable")
      last = account.holdings.where(account_provider_id: @snaptrade_account.account_provider&.id, external_id: nil).maximum(:date)
      return false if last && last < 3.days.ago.to_date
      total = @snaptrade_account.current_balance or return true
      (total - @snaptrade_account.cash_balance.to_d).abs >= 0.01
    end

    # Surface cash held in currencies other than the account's primary currency
    # as synthetic cash holdings (issue #1809). The primary currency stays in
    # account.cash_balance; without this, SnapTrade's secondary-currency cash
    # (e.g. USD cash in a CAD account) was silently discarded.
    def process_cash_holdings
      @snaptrade_account.non_primary_cash_entries.each do |entry|
        amount = parse_decimal(entry[:amount])
        next if amount.nil?

        # SnapTrade's per-currency cash includes money market / sweep funds
        # that are also reported as `cash_equivalent: true` positions and
        # imported as holdings — remove the overlap so the synthetic cash
        # holding doesn't double count them.
        amount -= @snaptrade_account.cash_equivalent_position_value(entry[:currency])

        security = Security.cash_for(account, currency: entry[:currency])

        Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Importing #{entry[:currency]} cash holding"

        import_adapter.import_holding(
          security: security,
          quantity: amount,
          amount: amount,
          currency: entry[:currency],
          date: Date.current,
          price: 1,
          external_id: "snaptrade_cash_#{entry[:currency].to_s.downcase}",
          account_provider_id: @snaptrade_account.account_provider&.id,
          source: "snaptrade",
          delete_future_holdings: false
        )
      rescue => e
        Rails.logger.error "SnaptradeAccount::HoldingsProcessor - Failed to import #{entry[:currency]} cash holding: #{e.class} - #{e.message}"
      end
    end

    def account
      @snaptrade_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_holding(data)
      symbol_data = extract_symbol_data(data)
      ticker = symbol_data["symbol"] || symbol_data[:symbol]

      # If that's still a hash, we need to go deeper or use raw_symbol
      if ticker.is_a?(Hash)
        ticker = symbol_data["raw_symbol"] || symbol_data[:raw_symbol]
      end

      # A cash row carries no symbol; any other row without one is unreadable.
      return symbol_data[:kind].to_s.casecmp?("cash") if ticker.blank?

      # Holdings can't be negative; a short only counts in the account total.
      quantity = parse_decimal(data["units"] || data[:units])
      return if quantity.nil?
      return true if quantity.negative?

      Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Processing holding for ticker: #{ticker}"

      # Resolve or create the security
      # The provider's own row, so the import adapter can carry a user's remap
      # and cost-basis lock forward; it returns the row the holding is on.
      security = resolve_security(ticker, symbol_data, account: account, account_provider_id: @snaptrade_account.account_provider&.id, provider_row: true)
      return unless security

      price = parse_decimal(data["price"] || data[:price])
      return if price.nil?

      # Calculate amount
      amount = quantity * price

      # Get the holding date (use current date if not provided)
      holding_date = Date.current

      # Must resolve to the same bucket as cash_equivalent_position_value, or
      # cash-equivalent positions stop cancelling out (#2729).
      currency = extract_currency(data, symbol_data, account.currency)

      Rails.logger.info "SnaptradeAccount::HoldingsProcessor - Importing holding: #{ticker} qty=#{quantity} price=#{price} currency=#{currency}"

      # Import the holding via the adapter
      holding = import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: holding_date,
        price: price,
        account_provider_id: @snaptrade_account.account_provider&.id,
        source: "snaptrade",
        delete_future_holdings: false
      )
      (@imported ||= []) << holding.security_id

      # Store cost basis if available. Both fields are per-share, which is
      # what update_holding_cost_basis expects — unlike the identically named
      # tax_lots[].cost_basis, which SnapTrade documents as a whole-lot total.
      avg_price = data["average_purchase_price"] || data[:average_purchase_price] ||
                  data["cost_basis"] || data[:cost_basis]
      if avg_price.present?
        update_holding_cost_basis(holding&.security || security, avg_price)
      end
      true
    end

    def update_holding_cost_basis(security, avg_cost)
      # Find the most recent holding and update cost basis if not locked
      holding = account.holdings
        .where(security: security)
        .where("cost_basis_source != 'manual' OR cost_basis_source IS NULL")
        .order(date: :desc)
        .first

      return unless holding

      # Store per-share cost, not total cost (cost_basis is per-share across the codebase)
      cost_basis = parse_decimal(avg_cost)
      return if cost_basis.nil?

      holding.update!(
        cost_basis: cost_basis,
        cost_basis_source: "provider"
      )
    end
end
