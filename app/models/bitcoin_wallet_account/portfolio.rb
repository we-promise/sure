# frozen_string_literal: true

# Own one security from a dated reconciliation boundary, with one read set for
# the whole range. Idle historical days do not produce new queries or writes.
class BitcoinWalletAccount::Portfolio
  def initialize(wallet)
    @wallet = wallet
    @account = wallet.account
  end

  def materialize
    first_date = wallet.baseline_at.to_date
    manual_ids = (account.trades.distinct.pluck(:security_id) + latest_other_holdings.map(&:security_id)).uniq - [ wallet.security_id ]
    traded_ids = account.trades.where(security_id: manual_ids).distinct.pluck(:security_id).to_set
    preload(first_date, manual_ids)
    manual = Holding::ForwardCalculator.new(account, security_ids: manual_ids).calculate
    manual.select! { |holding| holding.date.between?(first_date, Date.current) }
    persist_manual_holdings(manual)

    cash = wallet.baseline_cash_balance.to_d
    entries_by_date = account.entries.excluding_pending.includes(:entryable).where(date: first_date..Date.current)
      .where("date > ? OR created_at >= ?", first_date, wallet.baseline_at)
      .where.not(entryable_type: "Valuation").group_by(&:date)
    previous = account.balances.where(currency: account.currency, date: first_date.prev_day).first
    previous_holdings = previous ? previous.end_balance - previous.end_cash_balance : account.balance - account.cash_balance
    balances = []

    first_date.upto(Date.current) do |date|
      quantity = @quantities.fetch(date)
      price = cached_price(wallet.security_id, date) || 0
      import_bitcoin_holding(date, quantity, price)
      fill_untraded_positions(date, traded_ids)
      holdings_value = @holdings.values.select { |holding| holding.date == date }.sum(&:amount)
      entries = entries_by_date.fetch(date, [])
      start_cash = cash
      cash -= entries.sum(&:amount)
      inflows = entries.select { |entry| entry.amount.negative? }.sum(&:amount).abs
      outflows = entries.select { |entry| entry.amount.positive? }.sum(&:amount)
      non_cash_inflows = 0.to_d
      non_cash_outflows = 0.to_d
      entries.select(&:trade?).each do |entry|
        value = if entry.source == BitcoinWalletAccount::Processor::SOURCE
          entry.entryable.qty * price
        elsif entry.source == "bitcoin_wallet_reconciliation"
          0
        else
          entry.amount
        end
        non_cash_inflows += value if value.positive?
        non_cash_outflows += value.abs if value.negative?
      end
      balances << Balance::BalanceData.new(account: account, date: date, currency: account.currency,
        balance: cash + holdings_value, cash_balance: cash, start_cash_balance: start_cash,
        start_non_cash_balance: previous_holdings, cash_inflows: inflows, cash_outflows: outflows,
        non_cash_inflows: non_cash_inflows, non_cash_outflows: non_cash_outflows, cash_adjustments: 0,
        non_cash_adjustments: date == first_date ? holdings_value - previous_holdings : 0,
        net_market_flows: date == first_date ? 0 : holdings_value - previous_holdings - non_cash_inflows + non_cash_outflows, flows_factor: 1)
      previous_holdings = holdings_value
    end

    now = Time.current
    changed = balances.reject do |row|
      old = @balances[row.date]
      old && row.to_h.except(:account).all? { |key, value| old.public_send(key) == value }
    end
    if changed.any?
      account.balances.upsert_all(changed.map { |row| row.to_h.except(:account).merge(account_id: account.id, updated_at: now) },
        unique_by: %i[account_id date currency])
    end
    latest = balances.last
    account.holdings.reset
    account.update!(balance: latest.balance, cash_balance: latest.cash_balance) if latest
  end

  def self.price(security, currency, date)
    quote = security.prices.where(date: ..date).order(date: :desc).first
    return if quote.nil?
    return quote.price.to_d if quote.currency == currency

    rate = ExchangeRate.where(from_currency: quote.currency, to_currency: currency)
      .where(date: (date - ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS)..date).order(date: :desc).first
    quote.price.to_d * rate.rate.to_d if rate
  end

  private
    attr_reader :wallet, :account

    def preload(first_date, manual_ids)
      @holdings = account.holdings.where(currency: account.currency, date: first_date..Date.current)
        .index_by { |holding| [ holding.security_id, holding.date ] }
      @balances = account.balances.where(currency: account.currency, date: first_date..Date.current).index_by(&:date)
      ids = manual_ids + [ wallet.security_id ]
      recent = Security::Price.where(security_id: ids, date: first_date..Date.current).order(:date).to_a
      prior = Security::Price.where(security_id: ids).where("date < ?", first_date)
        .select("DISTINCT ON (security_id) security_prices.*").order(:security_id, date: :desc).to_a
      @prices = (prior + recent).group_by(&:security_id).transform_values { |rows| rows.sort_by(&:date) }
      currencies = (prior + recent).map(&:currency).uniq - [ account.currency ]
      @rates = ExchangeRate.where(from_currency: currencies, to_currency: account.currency)
        .where(date: (first_date - ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS)..Date.current)
        .order(:date).group_by(&:from_currency)
      changes = account.trades.where(security: wallet.security).joins(:entry)
        .where(entries: { date: first_date..Date.current }).group("entries.date").sum(:qty)
      quantity = wallet.quantity
      @quantities = {}
      Date.current.downto(first_date) do |date|
        @quantities[date] = quantity
        quantity -= changes.fetch(date, 0)
      end
    end

    def last_on(rows, date)
      return if rows.nil? || rows.empty?

      index = rows.bsearch_index { |row| row.date > date }
      index ? (index.positive? ? rows[index - 1] : nil) : rows.last
    end

    def cached_price(security_id, date)
      quote = last_on(@prices[security_id], date)
      return if quote.nil?
      return quote.price.to_d if quote.currency == account.currency

      rate = last_on(@rates[quote.currency], date)
      return unless rate && rate.date >= date - ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS

      quote.price.to_d * rate.rate.to_d
    end

    def import_bitcoin_holding(date, quantity, price)
      old = @holdings[[ wallet.security_id, date ]]
      amount = quantity * price
      return if old && old.account_provider_id == wallet.account_provider.id && old.qty == quantity && old.price == price && old.amount == amount

      row = Account::ProviderImportAdapter.new(account).import_holding(
        security: wallet.security, quantity: quantity, price: price, amount: amount,
        currency: account.currency, date: date, source: BitcoinWalletAccount::Processor::SOURCE,
        external_id: "bitcoin_wallet_#{wallet.id}_#{date.iso8601}", account_provider_id: wallet.account_provider.id
      )
      @holdings[[ wallet.security_id, date ]] = row
    end

    def persist_manual_holdings(rows)
      rows.each do |row|
        key = [ row.security_id, row.date ]
        existing = @holdings[key]
        next if existing&.account_provider_id.present?

        holding = existing || account.holdings.new(security_id: row.security_id, date: row.date, currency: row.currency)
        holding.assign_attributes(qty: row.qty, price: row.price, amount: row.amount)
        holding.save! if holding.changed?
        @holdings[key] = holding
      end
    end

    def latest_other_holdings
      @latest_other_holdings ||= account.holdings.where.not(security_id: wallet.security_id)
        .where(currency: account.currency, date: ..Date.current).select("DISTINCT ON (security_id) holdings.*")
        .order(:security_id, date: :desc).to_a
    end

    def fill_untraded_positions(date, traded_ids)
      latest_other_holdings.each do |holding|
        key = [ holding.security_id, date ]
        next if traded_ids.include?(holding.security_id) || @holdings.key?(key)

        price = cached_price(holding.security_id, date) || holding.price
        @holdings[key] = account.holdings.create!(security_id: holding.security_id, date: date, currency: account.currency,
          qty: holding.qty, price: price, amount: holding.qty * price,
          cost_basis: holding.cost_basis, cost_basis_source: holding.cost_basis_source)
      end
    end
end
