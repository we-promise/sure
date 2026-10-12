# The cost basis of a holding that has none materialized: the account's trades in
# the security, replayed up to the holding's date through the same tracker and
# the same rules the holding calculators use.
#
# It used to be a separate SQL average of every purchase ever made. That
# disagreed with the calculators wherever they relieve: after a position was
# sold in full and bought again, the average still counted the first round's
# purchases, and one internal movement made the position unknown forever rather
# than until it closed. Two implementations of one rule drift; this keeps one.
#
# Like the calculators:
#
# - Trades apply in entry order (date, then creation), a split at the open of
#   its ex-date, before that day's trades.
# - A buy's fee is part of what it cost; a sell relieves at the running average,
#   and a full close resets it.
# - An inbound internal movement brings in units at a cost nothing here knows,
#   so the basis is unknown until the position next crosses zero.
# - No usable rate for a foreign trade's day means its cost is unknown.
#
# A position closed on the holding's date keeps the cost of the units it last
# held. A sale's gain is measured against the holding on its own date, which,
# after a full close, holds nothing: without that, every sale that closed a
# position would have no gain at all.
#
# The replay starts from an empty position, as the forward calculator does.
# The reverse calculator also counts units held before the first imported
# trade, at an unknown cost; doing that here would turn the average of the
# known purchases, which the fallback has always shown for such a holding, into
# no figure at all, and is a change of its own.
#
# Unlike them, it never looks a rate up per trade: the trade's own rate comes
# first, then the table's for that exact day, both read with the trades, so the
# whole replay is two queries -- the trades and the splits.
class Holding::CostBasisFallback
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  def initialize(holding)
    @holding = holding
    @account = holding.account
  end

  # Money in the holding's currency, or nil when the basis is unknown.
  def average_cost
    tracker = Holding::CostBasisTracker.new
    position = 0.to_d
    unknown = false
    closed_at = nil

    events.each do |event|
      if event.is_a?(Security::Split)
        position = Security::Split.scale(position, event.ratio)
        tracker.split(event.ratio)
        next
      end

      previous = position
      position += event.qty

      # What the units cost just before the trade that closes the position,
      # before the tracker resets.
      closed_at = (unknown ? nil : tracker.average_cost) if previous.positive? && position <= 0

      if event.internal_movement? && event.qty.positive?
        unknown = true
      else
        tracker.apply(effective_trade_price(event, date: event.entry_date), event.qty)
      end

      # Only a genuine downward crossing releases it: a position that was
      # already non-positive never held the units in question.
      unknown = false if previous.positive? && position <= 0
    end

    return nil if unknown

    cost = position.positive? ? tracker.average_cost : closed_at
    cost && Money.new(cost, @holding.currency)
  end

  private
    def trades
      @trades ||= account.trades
        .with_entry
        .joins(ActiveRecord::Base.sanitize_sql_array([
          "LEFT JOIN exchange_rates ON (
            exchange_rates.date = entries.date AND
            exchange_rates.from_currency = trades.currency AND
            exchange_rates.to_currency = ?
          )", account.currency
        ]))
        .where(security_id: @holding.security_id)
        .where("entries.date <= ?", @holding.date)
        .select("trades.*, entries.date AS entry_date, exchange_rates.rate AS table_rate")
        .order("entries.date ASC, entries.created_at ASC, entries.id ASC")
        .to_a
    end

    def splits
      @splits ||= Security::Split
        .where(security_id: @holding.security_id, ex_date: ..@holding.date)
        .order(:ex_date)
        .to_a
    end

    # Splits and trades in the order they took effect: a split before the
    # trades of its ex-date, which are already in post-split units.
    def events
      @events ||= begin
        by_date = trades.group_by(&:entry_date)
        dates = (by_date.keys + splits.map(&:ex_date)).uniq.sort
        splits_by_date = splits.index_by(&:ex_date)

        dates.flat_map { |date| [ splits_by_date[date], *by_date[date] ].compact }
      end
    end

    # The trade's own rate, else the table's for its day -- never a lookup, so
    # never a fetch. A rate Trade's validation would refuse (not a finite
    # number above zero) converts nothing, as in Money#exchange_to.
    def convert_to_account_currency(amount, trade, date:)
      return amount if trade.currency == account.currency

      rate = usable_rate(trade.exchange_rate.presence || trade.table_rate)
      return nil if rate.nil?

      amount * rate
    end

    def usable_rate(value)
      return nil if value.nil?

      rate = Float(value.to_s, exception: false)
      return nil if rate.nil? || !rate.finite? || rate <= 0

      value.to_d
    end
end
