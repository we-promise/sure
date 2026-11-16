class Security::Price::ImportWindows
  Window = Data.define(:start_date, :end_date)

  def initialize(account, today: Date.current)
    @account = account
    @today = today
  end

  def to_h
    current_ids = account.current_holdings.pluck(:security_id).to_set
    first_trade_dates = {}
    last_trade_dates = {}
    last_buy_dates = {}
    last_trade_changed_at = {}
    trade_quantities = {}
    account.trades.group(:security_id).pluck(
      :security_id,
      Arel.sql("MIN(entries.date)"),
      Arel.sql("MAX(entries.date) FILTER (WHERE trades.qty <> 0)"),
      Arel.sql("MAX(entries.date) FILTER (WHERE trades.qty > 0)"),
      Arel.sql("MAX(GREATEST(entries.updated_at, trades.updated_at)) FILTER (WHERE trades.qty <> 0)"),
      Arel.sql("SUM(trades.qty)")
    ).each do |security_id, first_date, last_date, last_buy_date, trade_changed_at, qty|
      first_trade_dates[security_id] = first_date
      last_trade_dates[security_id] = last_date
      last_buy_dates[security_id] = last_buy_date
      last_trade_changed_at[security_id] = trade_changed_at
      trade_quantities[security_id] = qty
    end

    first_held_dates = {}
    last_held_dates = {}
    last_holding_dates = {}
    last_holding_updated_at = {}
    last_provider_dates = {}
    provider_holding_ids = Set.new
    account.holdings.group(:security_id).pluck(
      :security_id,
      Arel.sql("MIN(holdings.date) FILTER (WHERE holdings.qty > 0)"),
      Arel.sql("MAX(holdings.date) FILTER (WHERE holdings.qty > 0)"),
      Arel.sql("MAX(holdings.date)"),
      Arel.sql("MAX(holdings.updated_at)"),
      Arel.sql("MAX(holdings.date) FILTER (WHERE holdings.account_provider_id IS NOT NULL)")
    ).each do |security_id, first_date, last_date, holding_date, holding_updated_at, provider_date|
      first_held_dates[security_id] = first_date if first_date
      last_held_dates[security_id] = last_date if last_date
      last_holding_dates[security_id] = holding_date
      last_holding_updated_at[security_id] = holding_updated_at
      if provider_date
        provider_holding_ids.add(security_id)
        last_provider_dates[security_id] = provider_date
      end
    end

    # A manual position can reopen before holdings are rematerialized: a new
    # trade, a backdated one, or an edit to an existing one. Net quantity in
    # either direction counts, because the materializer writes holdings with
    # upsert_all, so a short is not stopped by Holding's qty >= 0 validation.
    # A zero holding written after every trade change is authoritative even
    # when raw trade quantities disagree (for example, after a reverse split).
    # A deleted trade leaves no row to compare, so deleting a closing trade is
    # picked up on the next sync, once holdings are rebuilt.
    manual_open_ids = trade_quantities.filter_map do |id, qty|
      next if qty.nil? || qty.zero? || provider_holding_ids.include?(id)

      last_holding_date = last_holding_dates[id]
      changed_at = last_trade_changed_at[id]
      id if last_holding_date.nil? ||
        (last_trade_dates[id] && last_trade_dates[id] > last_holding_date) ||
        (changed_at && changed_at > last_holding_updated_at[id])
    end.to_set
    provider_reopened_ids = provider_holding_ids.filter_map do |id|
      id if last_buy_dates[id] && last_buy_dates[id] > last_provider_dates[id]
    end.to_set

    ids = current_ids | manual_open_ids | provider_reopened_ids | first_trade_dates.keys | first_held_dates.keys
    return {} if ids.empty?

    account_start_date = account.start_date

    ids.each_with_object({}) do |security_id, windows|
      start_date = [
        first_trade_dates[security_id],
        first_held_dates[security_id],
        (account_start_date if provider_holding_ids.include?(security_id))
      ].compact.min || account_start_date

      end_date = if current_ids.include?(security_id) || manual_open_ids.include?(security_id) || provider_reopened_ids.include?(security_id)
        today
      else
        [ last_trade_dates[security_id], last_held_dates[security_id] ].compact.max
      end

      windows[security_id] = Window.new(start_date: start_date, end_date: end_date) if end_date
    end
  end

  private
    attr_reader :account, :today
end
