class EtoroAccount::ActivitiesProcessor
  include EtoroAccount::DataHelpers

  # How far a stored buy may be from the closes of its position and still
  # count as theirs. Entries keep amounts to 4 places.
  QUANTITY_TOLERANCE = BigDecimal("0.00000001")
  AMOUNT_TOLERANCE = BigDecimal("0.0001")

  STORED_CLOSE_ID = /\Aetoro_position_(.+)_close_\d+\z/

  StoredTrade = Data.define(:date, :security_id, :quantity, :amount)

  attr_reader :failed_count

  def initialize(etoro_account, securities: nil)
    @etoro_account = etoro_account
    @securities = securities
    @failed_count = 0
  end

  # eToro reports positions, not orders: each real-asset position becomes a
  # buy on the day it opened and a sell for each close. Positions that are not
  # real assets (see DataHelpers#real_asset?) are left out, their equity being
  # carried as cash. The buy of an open position is rewritten on every sync,
  # as a partial close changes it. A stored close, or the stored buy of a
  # fully closed position, is rewritten only when it no longer matches: its
  # trades go on another security now (see DataHelpers#trade_security_for),
  # it is on another day or on other shares (a split found since, see
  # #closed_units), or a buy does not add up to the closes of its position.
  #
  # A position can have stored closes its trade history no longer lists, when
  # the account is linked to a new connection whose history starts later.
  # Those closes keep their stored figures, and follow the position when its
  # trades go on another security; a split found later leaves them on the
  # shares they were stored on. The position's buy keeps its stored cost, as
  # the closes listed are only part of the position, and takes the units of
  # all its closes and of whatever is still open, so that they add up.
  def process
    return { buys: 0, sells: 0 } unless account.present?

    move_reported_holdings!

    buys = positions_by_id.sum do |position_id, legs|
      next 0 if buy_stored?(position_id, legs)

      import_buy(position_id, legs) ? 1 : 0
    end

    sells = closed_trades.sum do |trade|
      next 0 if sell_stored?(trade)

      import_sell(trade) ? 1 : 0
    end

    sells += unlisted_closes.sum do |position_id, external_ids|
      instrument_id = instrument_id_of(positions_by_id[position_id])
      external_ids.sum do |external_id|
        next 0 if on_current_security?(stored_trades[external_id], instrument_id)

        import_unlisted_close(position_id, external_id, instrument_id) ? 1 : 0
      end
    end

    # Once the trades have moved, the securities they left may be unused.
    discard_unused_securities(@left_security_ids) if @left_security_ids.present?

    { buys: buys, sells: sells }
  end

  private

    def account
      @etoro_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @etoro_account.currency
    end

    def instruments_map
      @etoro_account.instruments_map
    end

    def provider_id
      @etoro_account.account_provider&.id
    end

    # The eToro trades already stored, by external_id.
    def stored_trades
      @stored_trades ||= account.entries
        .where(source: "etoro", entryable_type: "Trade")
        .where.not(external_id: nil)
        .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
        .pluck("entries.external_id", "entries.date", "trades.security_id", "trades.qty", "entries.amount")
        .to_h do |external_id, date, security_id, quantity, amount|
          [ external_id, StoredTrade.new(date: date, security_id: security_id, quantity: quantity, amount: amount) ]
        end
    end

    # Stored close external_ids by position ID.
    def stored_close_ids_by_position
      @stored_close_ids_by_position ||= stored_trades.keys.grep(STORED_CLOSE_ID).group_by { |external_id| external_id[STORED_CLOSE_ID, 1] }
    end

    # The stored closes of each position that its trade history does not
    # list, for the positions that have any.
    def unlisted_closes
      @unlisted_closes ||= positions_by_id.each_with_object({}) do |(position_id, legs), unlisted|
        external_ids = stored_close_ids_by_position.fetch(position_id, []) - legs[:closed].filter_map { |trade| sell_external_id(trade) }
        unlisted[position_id] = external_ids if external_ids.any?
      end
    end

    # The units a position's unlisted closes took out, as stored.
    def unlisted_units(position_id)
      unlisted_closes.fetch(position_id, []).sum(BigDecimal("0")) { |external_id| -stored_trades[external_id].quantity }
    end

    def buy_stored?(position_id, legs)
      stored = stored_trades[buy_external_id(position_id)]
      return false unless stored

      buy = buy_figures(legs[:open], legs[:closed])
      if unlisted_closes.key?(position_id)
        return stored_as?(stored, buy[:date], instrument_id_of(legs)) &&
          within?(stored.quantity, buy[:quantity] + unlisted_units(position_id), QUANTITY_TOLERANCE)
      end
      return false if legs[:open]

      stored_as?(stored, buy[:date], instrument_id_of(legs)) &&
        within?(stored.quantity, buy[:quantity], QUANTITY_TOLERANCE) &&
        within?(stored.amount, buy[:amount], AMOUNT_TOLERANCE)
    end

    # A stored close is written again when it is now on other shares, as
    # after a split eToro's prices show since it was imported.
    def sell_stored?(trade)
      stored = stored_trades[sell_external_id(trade)]
      quantity = closed_units(trade)
      stored.present? && quantity.present? &&
        stored_as?(stored, parse_date(field(trade, "closeTimestamp")), field(trade, "instrumentID")) &&
        within?(stored.quantity, -quantity, QUANTITY_TOLERANCE)
    end

    # Whether a stored trade is on the given day and on the security its
    # instrument's trades go on now.
    def stored_as?(stored, date, instrument_id)
      stored.date == date && on_current_security?(stored, instrument_id)
    end

    # An instrument that resolves to nothing leaves its stored trades as they
    # are.
    def on_current_security?(stored, instrument_id)
      security = trade_security_for(instrument_id)
      security.nil? || stored.security_id == security.id
    end

    def within?(stored, expected, tolerance)
      stored.present? && (stored - expected).abs <= tolerance
    end

    def open_positions
      @open_positions ||= Array(@etoro_account.raw_positions_payload).select { |position| real_asset?(position) }
    end

    def closed_trades
      @closed_trades ||= Array(@etoro_account.raw_trades_payload).select { |trade| real_asset?(trade) }
    end

    # A partly closed position can be both open and in the closed trades under
    # one ID, so its buy covers the units of both.
    def positions_by_id
      @positions_by_id ||= begin
        legs = Hash.new { |hash, key| hash[key] = { open: nil, closed: [] } }
        open_positions.each { |position| legs[field(position, "positionID").to_s][:open] = position }
        closed_trades.each { |trade| legs[field(trade, "positionId").to_s][:closed] << trade }
        legs.except("")
      end
    end

    def instrument_id_of(legs)
      field(legs[:open] || legs[:closed].first, "instrumentID")
    end

    def buy_external_id(position_id)
      "etoro_position_#{position_id}_open"
    end

    def sell_external_id(trade)
      closed_at = parse_time(field(trade, "closeTimestamp"))
      "etoro_position_#{field(trade, "positionId")}_close_#{closed_at.to_i}" if closed_at
    rescue ArgumentError
      nil
    end

    # Units, cost and opening day of a position's buy, which covers its
    # closed legs and whatever is still open, all on today's shares.
    def buy_figures(open, closed)
      quantity = closed.sum(BigDecimal("0")) { |trade| closed_units(trade) || 0 }
      amount = closed.sum(BigDecimal("0")) { |trade| parse_decimal(field(trade, "investment")) || 0 }
      if open
        quantity += parse_decimal(field(open, "units")) || 0
        amount += position_cost(open) || 0
      end
      date = parse_date(open ? field(open, "openDateTime") : field(closed.first, "openTimestamp"))

      { quantity: quantity, amount: amount, date: date }
    end

    # The units of a closed leg on today's shares. eToro's prices are stored
    # on today's shares too, and its open positions are restated on them, so
    # the holdings history counts one share basis throughout. The money is
    # the same either way: a sell's price moves by the inverse.
    def closed_units(trade)
      units = parse_decimal(field(trade, "units"))
      factor = split_factor_after(field(trade, "instrumentID"), session_date(field(trade, "closeTimestamp")), rate: field(trade, "closeRate"))
      units && factor != 1 ? Security::Split.scale(units, factor) : units
    end

    def import_buy(position_id, legs)
      buy = buy_figures(legs[:open], legs[:closed])
      stored = stored_trades[buy_external_id(position_id)]
      buy = buy.merge(quantity: buy[:quantity] + unlisted_units(position_id), amount: stored.amount) if stored && unlisted_closes.key?(position_id)
      return false unless buy[:quantity].positive? && buy[:amount].positive? && buy[:date]

      security = trade_security_for(instrument_id_of(legs))
      return false unless security

      import_adapter.import_trade(
        external_id: buy_external_id(position_id),
        security: security,
        quantity: buy[:quantity],
        price: buy[:amount] / buy[:quantity],
        amount: buy[:amount],
        currency: currency,
        date: buy[:date],
        source: "etoro",
        activity_label: "Buy"
      )

      true
    rescue => e
      capture_failure("buy for position #{position_id}", e)
      false
    end

    def import_sell(trade)
      position_id = field(trade, "positionId").to_s
      date = parse_date(field(trade, "closeTimestamp"))
      quantity = closed_units(trade)
      proceeds = (parse_decimal(field(trade, "investment")) || 0) + (parse_decimal(field(trade, "netProfit")) || 0)
      external_id = sell_external_id(trade)
      return false if position_id.blank? || date.nil? || external_id.nil? || quantity.nil? || !quantity.positive?

      security = trade_security_for(field(trade, "instrumentId"))
      return false unless security

      import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: -quantity,
        price: proceeds / quantity,
        amount: -proceeds,
        currency: currency,
        date: date,
        source: "etoro",
        activity_label: "Sell"
      )

      true
    rescue => e
      capture_failure("sell for position #{position_id}", e)
      false
    end

    def import_unlisted_close(position_id, external_id, instrument_id)
      stored = stored_trades[external_id]
      security = trade_security_for(instrument_id)
      return false unless security && stored.quantity.nonzero?

      import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: stored.quantity,
        price: stored.amount / stored.quantity,
        amount: stored.amount,
        currency: currency,
        date: stored.date,
        source: "etoro",
        activity_label: "Sell"
      )

      true
    rescue => e
      capture_failure("sell for position #{position_id}", e)
      false
    end

    # eToro's holdings of earlier days stay on the security they were
    # reported on. When every stored trade of a security moves to one other
    # security in this run (eToro renamed the instrument, or its symbol now
    # resolves differently), its holdings move as well: left behind, those
    # days would count the units twice, there and in the history worked back
    # from the trades. A security trades still go to keeps its holdings, as
    # they may be partly those trades'. So do the reported holdings of a
    # security whose trades go to several securities, as they cannot be split
    # between them, while its calculated ones go: with no trades left,
    # nothing works them out again. This runs before the trades move, so a
    # run that stops partway leaves them for the next one to find.
    def move_reported_holdings!
      return unless provider_id

      moves, split = movable_securities
      return if moves.empty? && split.empty?

      @left_security_ids = moves.keys + split
      account.holdings.where(security_id: split, account_provider_id: nil).delete_all if split.any?
      moves.each { |old_id, new_id| Holding.transaction { move_holdings(old_id, new_id) } }

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "EtoroAccount::ActivitiesProcessor - Moved the holdings of #{moves.size} and dropped the calculated holdings of #{split.size} security(ies) eToro's instruments no longer resolve to.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: {
          moves: moves.first(100).map { |old_id, new_id| { from: old_id, to: new_id } },
          split: split.first(100),
          etoro_account_id: @etoro_account.id
        }
      )
    end

    # The securities whose stored trades all go to other securities in this
    # run and that no trade goes to now: old security ID => new one for those
    # whose trades all go to one security, and the IDs of those whose trades
    # go to several.
    def movable_securities
      planned = planned_security_ids
      in_use = planned.values.to_set.merge(open_positions.filter_map { |position| trade_security_for(field(position, "instrumentID"))&.id })
      targets = Hash.new { |hash, security_id| hash[security_id] = Set.new }
      stored_trades.each { |external_id, stored| targets[stored.security_id] << planned[external_id] }

      leaving = targets.reject { |old_id, new_ids| new_ids.include?(nil) || in_use.include?(old_id) }
      moves, split = leaving.partition { |_old_id, new_ids| new_ids.size == 1 }
      [ moves.to_h { |old_id, new_ids| [ old_id, new_ids.first ] }, split.map(&:first) ]
    end

    # The security each trade this run writes goes on, by external_id. Nil
    # for an instrument eToro has not described, whose trades stay put.
    def planned_security_ids
      planned = {}
      positions_by_id.each do |position_id, legs|
        security_id = trade_security_for(instrument_id_of(legs))&.id
        planned[buy_external_id(position_id)] = security_id
        unlisted_closes.fetch(position_id, []).each { |external_id| planned[external_id] = security_id }
      end
      closed_trades.each do |trade|
        external_id = sell_external_id(trade)
        planned[external_id] = trade_security_for(field(trade, "instrumentID"))&.id if external_id
      end
      planned
    end

    # Calculated holdings are worked out again from the trades, and today's
    # snapshot already has the units on the new security. Holdings a user
    # moved to this security go as well: their trades leave with the others,
    # and the holdings import no longer carries the move to new days.
    def move_holdings(old_id, new_id)
      holdings = account.holdings.where(security_id: old_id)
      holdings.where(account_provider_id: nil).delete_all

      reported = holdings.where(account_provider_id: provider_id)
      reported.where(date: Date.current..).delete_all
      reported.find_each { |holding| move_holding(holding, new_id) }
    end

    # A calculated holding of the day on the new security gives way, and a
    # reported one takes in the units. A holding moved there is the new
    # security's own, no longer one a user moved.
    def move_holding(holding, new_id)
      target = account.holdings.find_by(security_id: new_id, date: holding.date, currency: holding.currency)

      if target.nil? || target.account_provider_id.nil?
        target&.delete
        holding.update!(security_id: new_id, provider_security_id: new_id, security_locked: false)
      elsif target.account_provider_id == provider_id
        add_to_holding!(target, holding)
      end
    end

    def add_to_holding!(target, holding)
      quantity = target.qty + holding.qty
      amount = target.amount + holding.amount
      attributes = { qty: quantity, amount: amount }

      if quantity.positive?
        attributes[:price] = amount / quantity
        if target.cost_basis && holding.cost_basis && !target.cost_basis_locked?
          attributes[:cost_basis] = (target.cost_basis * target.qty + holding.cost_basis * holding.qty) / quantity
        end
      end

      target.update!(attributes)
      holding.delete
    end

    def capture_failure(what, error)
      @failed_count += 1
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "EtoroAccount::ActivitiesProcessor - Failed to import #{what}: #{error.message}",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { etoro_account_id: @etoro_account.id }
      )
    end
end
