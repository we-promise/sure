# frozen_string_literal: true

# A Bitcoin publisher owns one security, not the account's entire portfolio.
# Start at its reconciliation boundary and leave every earlier record intact.
class BitcoinWalletAccount::Portfolio
  def initialize(wallet)
    @wallet = wallet
    @account = wallet.account
  end

  def materialize
    first_date = wallet.baseline_at.to_date
    manual_ids = (account.trades.distinct.pluck(:security_id) + latest_other_holdings.map(&:security_id)).uniq - [ wallet.security_id ]
    manual = Holding::ForwardCalculator.new(account, security_ids: manual_ids).calculate
    manual.select! { |holding| holding.date.between?(first_date, Date.current) }
    persist_manual_holdings(manual)

    cash = wallet.baseline_cash_balance.to_d
    cash_entries = account.entries.excluding_pending.where(date: first_date..Date.current)
      .where("date > ? OR created_at >= ?", first_date, wallet.baseline_at)
      .where.not(entryable_type: "Valuation").group_by(&:date)

    previous = account.balances.where(currency: account.currency, date: first_date.prev_day).first
    previous_holdings = previous ? previous.end_balance - previous.end_cash_balance : account.balance - account.cash_balance
    balances = []

    first_date.upto(Date.current) do |date|
      quantity = quantity_on(date)
      price = self.class.price(wallet.security, account.currency, date) || 0
      Account::ProviderImportAdapter.new(account).import_holding(
        security: wallet.security, quantity: quantity, price: price, amount: quantity * price,
        currency: account.currency, date: date, source: BitcoinWalletAccount::Processor::SOURCE,
        external_id: "bitcoin_wallet_#{wallet.id}_#{date.iso8601}", account_provider_id: wallet.account_provider.id
      )
      fill_untraded_positions(date, manual_ids)
      holdings_value = account.holdings.where(date: date, currency: account.currency).sum(:amount)
      entries = cash_entries.fetch(date, [])
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
    account.balances.upsert_all(balances.map { |row| row.to_h.except(:account).merge(account_id: account.id, updated_at: now) },
      unique_by: %i[account_id date currency])
    latest = balances.last
    account.holdings.reset
    account.update!(balance: latest.balance, cash_balance: latest.cash_balance) if latest
  end

  def self.price(security, currency, date)
    quote = security.prices.where(date: ..date).order(date: :desc).first
    return if quote.nil?
    return quote.price.to_d if quote.currency == currency

    rate = ExchangeRate.find_or_fetch_rate(from: quote.currency, to: currency, date: date)
    quote.price.to_d * rate.rate.to_d if rate
  end

  private
    attr_reader :wallet, :account

    def quantity_on(date)
      # The current snapshot is authoritative; roll backwards only through
      # movements observed after the source-set reconciliation boundary.
      later = account.trades.where(security: wallet.security).joins(:entry)
        .where("entries.date > ? AND entries.date <= ?", date, Date.current).sum(:qty)
      wallet.quantity - later
    end

    def persist_manual_holdings(rows)
      rows.each do |row|
        existing = account.holdings.find_by(security_id: row.security_id, date: row.date, currency: row.currency)
        next if existing&.account_provider_id.present?

        holding = existing || account.holdings.new(security_id: row.security_id, date: row.date, currency: row.currency)
        holding.assign_attributes(qty: row.qty, price: row.price, amount: row.amount)
        holding.save! if holding.changed?
      end
    end

    def latest_other_holdings
      @latest_other_holdings ||= account.holdings.where.not(security_id: wallet.security_id)
        .where(currency: account.currency).select("DISTINCT ON (security_id) holdings.*")
        .order(:security_id, date: :desc).to_a
    end

    def fill_untraded_positions(date, security_ids)
      traded_ids = account.trades.where(security_id: security_ids).distinct.pluck(:security_id)
      latest_other_holdings.each do |holding|
        next if traded_ids.include?(holding.security_id)
        next if account.holdings.exists?(security_id: holding.security_id, date: date, currency: account.currency)

        price = self.class.price(holding.security, account.currency, date) || holding.price
        account.holdings.create!(security_id: holding.security_id, date: date, currency: account.currency,
          qty: holding.qty, price: price, amount: holding.qty * price,
          cost_basis: holding.cost_basis, cost_basis_source: holding.cost_basis_source)
      end
    end
end
