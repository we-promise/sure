# Divides the figures of a trading account that holds more than one currency
# between one Sure cash account per currency and one stocks account per
# currency with positions or trades.
#
# Sure keeps one cash figure per investment account, in the account's
# currency. Foreign cash shown as a holding of the home account would be
# carried back at today's amount through every past day, since a holding
# without trades keeps its current size; an account per currency instead
# works its history back from its own transactions.
class MoomooAccount::CurrencySplit
  include MoomooAccount::DataHelpers

  # The prefix of each currency's figures in moomoo's funds
  # ("us_net_cash_power").
  FUNDS_CURRENCY_PREFIXES = {
    "sg" => "SGD",
    "us" => "USD",
    "hk" => "HKD",
    "cn" => "CNH",
    "jp" => "JPY",
    "au" => "AUD",
    "my" => "MYR",
    "kr" => "KRW"
  }.freeze
  # How far the currencies' buying power, together, may be from the
  # account's cash and money market funds before Sure refuses to divide
  # them by it.
  TOLERANCE = BigDecimal("0.05")

  class Mismatch < StandardError; end

  # `moomoo_account` is the primary row; `funds` and `positions` are the
  # snapshot being applied.
  def initialize(moomoo_account, funds:, positions:, date: Date.current)
    @moomoo_account = moomoo_account
    @funds = funds.is_a?(Hash) ? funds : {}
    @positions = Array(positions).select { |position| position.is_a?(Hash) }
    @date = date
  end

  # Every currency the account holds or has held, home currency first: cash
  # and positions today, the stored trades and cash log rows, and the
  # currency accounts already set up. An account that has only ever held
  # one currency, even a foreign one, is not split: its Sure account keeps
  # everything rather than dropping to nothing in the home currency. One
  # already split stays split, so its accounts keep their links.
  def currencies
    @currencies ||= begin
      held = (cash_by_currency.select { |_currency, amount| amount.nonzero? }.keys +
        @positions.map { |position| position_currency(position) } +
        stored_fill_currencies +
        Array(moomoo_account.raw_cash_logs_payload).filter_map { |row| cash_log_currency(row) if row.is_a?(Hash) } +
        moomoo_account.currency_accounts.map(&:currency)).compact.uniq
      split = held.size > 1 || moomoo_account.currency_accounts.any?
      split ? [ home_currency, *held ].uniq : [ home_currency ]
    end
  end

  def multiple_currencies?
    currencies.size > 1
  end

  # The currencies that get a stocks account beside their cash account: the
  # ones with positions today or stored trades, and the ones that already
  # have a stocks account.
  def stock_currencies
    @stock_currencies ||= (@positions.map { |position| position_currency(position) } +
      stored_fill_currencies +
      [ moomoo_account, *moomoo_account.currency_accounts ].select(&:stocks_role?).map(&:currency)).compact.uniq & currencies
  end

  # Each currency's balance and cash today, in that currency. Its cash is its
  # buying power, which counts the money market funds moomoo sweeps idle cash
  # into (moomoo Cash Plus), scaled so that the currencies add up to moomoo's
  # cash and fund assets; its balance adds the market value of its positions.
  # Raises Mismatch when the buying power is too far from those totals to be
  # scaled to them, or Sure has no exchange rate to compare it with.
  def balances
    cash = scaled_cash

    currencies.to_h do |currency|
      held = cash.fetch(currency, BigDecimal("0"))
      value = @positions.select { |position| position_currency(position) == currency }
        .sum(BigDecimal("0")) { |position| position_value(position) || 0 }
      [ currency, { balance: held + value, cash: held } ]
    end
  end

  private

    attr_reader :moomoo_account

    def home_currency
      moomoo_account.currency
    end

    def cash_by_currency
      @cash_by_currency ||= FUNDS_CURRENCY_PREFIXES.each_with_object({}) do |(prefix, currency), cash|
        amount = parse_decimal(@funds["#{prefix}_net_cash_power"])
        cash[currency] = amount if amount
      end
    end

    def scaled_cash
      raise Mismatch, "funds list no cash per currency" if cash_by_currency.empty?

      pool = (parse_decimal(@funds["cash"]) || 0) + (parse_decimal(@funds["funds_assets"]) || 0)
      reported = cash_by_currency.sum(BigDecimal("0")) { |currency, amount| in_home_currency(amount, currency) }
      return cash_by_currency if reported.zero? && pool.zero?

      ratio = pool / reported unless reported.zero?
      unless ratio && (ratio - 1).abs <= TOLERANCE
        raise Mismatch, "cash per currency is not zero, but the cash and fund assets are" if pool.zero?
        raise Mismatch, "cash per currency comes to #{(reported * 100 / pool).round(1)}% of the cash and fund assets"
      end

      cash_by_currency.transform_values { |amount| (amount * ratio).round(4) }
    end

    def in_home_currency(amount, currency)
      return amount if currency == home_currency || amount.zero?

      Money.new(amount, currency).exchange_to(home_currency, date: @date).amount
    rescue Money::ConversionError
      raise Mismatch, "no #{currency} to #{home_currency} exchange rate for #{@date}"
    end

    def stored_fill_currencies
      orders = moomoo_account.orders_map
      by_code = @positions.index_by { |position| position["code"].to_s }.reverse_merge(moomoo_account.positions_by_code)
      Array(moomoo_account.raw_fills_payload).filter_map { |fill| fill_currency(fill, orders, by_code) if fill.is_a?(Hash) }
    end
end
