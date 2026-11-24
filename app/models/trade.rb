class Trade < ApplicationRecord
  include Entryable, Monetizable

  monetize :price
  monetize :fee

  belongs_to :security
  belongs_to :category, optional: true
  # The acquisition a sale says it sold from. Set by the user, never by a
  # provider, so it stays editable on a linked sale.
  belongs_to :lot_source_entry, class_name: "Entry", optional: true

  # Use the same activity labels as Transaction
  ACTIVITY_LABELS = Transaction::ACTIVITY_LABELS.dup.freeze

  REWARD_PROVIDERS = { "kraken" => KrakenAccount::LedgerProcessor }.freeze
  NonCashReward = Data.define(:quantity, :unit_price) do
    def value
      unit_price * quantity if unit_price
    end
  end

  # The labels that mean the asset went somewhere else you own rather than
  # being bought or sold.
  #
  # Deliberately NOT `Transaction::INTERNAL_MOVEMENT_LABELS`, which also holds
  # "Exchange". On cash that means a currency exchange and is internal; on a
  # security the label covers "currency **or security** exchanges"
  # (docs/onboarding/guide.md), and a security-for-security exchange can
  # dispose of an appreciated asset.
  #
  # The two errors are not symmetrical. Listing a movement that was not a sale
  # is visible and correctable; erasing a realized gain is neither — it simply
  # is not there. So only labels that unambiguously preserve ownership are
  # excluded, and an ambiguous one is left where the user can see it.
  INTERNAL_MOVEMENT_LABELS = %w[Transfer Sweep\ In Sweep\ Out].freeze

  # The labels that only say which side of the trade it is.
  SIDE_LABELS = Trade::CreateForm::SECURITY_TRADE_LABELS.values_at("buy", "sell").freeze

  # Kept as the provider-facing label for direct wallet transfers. Cost-basis
  # calculations use INTERNAL_MOVEMENT_LABELS so API-created sweeps follow the
  # same ownership-preserving rule.
  TRANSFER_LABEL = "Transfer".freeze

  validates :qty, presence: true
  validates :price, :currency, presence: true
  validates :investment_activity_label, inclusion: { in: ACTIVITY_LABELS }, allow_nil: true

  def exchange_rate
    extra&.dig("exchange_rate")
  end

  def exchange_rate=(value)
    if value.blank?
      self.extra = (extra || {}).merge("exchange_rate" => nil, "exchange_rate_invalid" => false)
    else
      begin
        normalized_value = Float(value)
        raise ArgumentError unless normalized_value.finite?

        self.extra = (extra || {}).merge("exchange_rate" => normalized_value, "exchange_rate_invalid" => false)
      rescue ArgumentError, TypeError
        self.extra = (extra || {}).merge("exchange_rate" => value, "exchange_rate_invalid" => true)
      end
    end
  end

  validate :exchange_rate_must_be_valid
  validate :lot_source_entry_must_be_a_lot_choice, if: -> { lot_source_entry_id_changed? && lot_source_entry_id }
  before_validation :drop_lot_source_entry, if: -> { lot_source_entry_id && !lot_source_entry_id_changed? && qty && !disposal? }

  # Trade types for categorization
  def buy?
    qty.positive?
  end

  def sell?
    qty.negative?
  end

  def income_activity?
    Portfolio::FlowClassifier::INCOME_LABELS.include?(investment_activity_label)
  end

  def non_cash_reward
    return unless qty&.positive? && entry&.amount&.zero?

    source = entry.source
    status = REWARD_PROVIDERS[source]&.reward_price_status(extra[source] || {})
    return unless status

    unit_price = price_money if status == :historical && price&.positive?
    NonCashReward.new(qty, unit_price)
  end

  # A sale that can name the lot it sold from.
  def disposal?
    sell? && !internal_movement?
  end

  # A negative quantity that left for another account you own. It looks exactly
  # like a sale — same sign, same shape — and only the label tells them apart.
  def internal_movement?
    INTERNAL_MOVEMENT_LABELS.include?(investment_activity_label)
  end

  # The acquisitions this sale can name as the lot it sold from: buys and
  # transfers-in of its security, in its account, that the replay applies
  # before it (an earlier date, or the same date and entered no later: a
  # purchase stamped with the sale's own created_at replays first, see
  # Holding::PortfolioCache#trades), leaving out a lot sales dated before it had already
  # emptied. Only a sale in an account that sells by fifo has any, since under
  # average a sale relieves every lot pro rata. The choice the sale already
  # holds is always among them, so an edit keeps it, and is replayed only
  # while it names a lot that is still open; a new choice must be open by then.
  def lot_choices
    return Entry.none unless disposal? && entry&.account&.cost_basis_fifo?

    acquisitions = entry.account.entries
      .where(entryable_type: "Trade", entryable_id: Trade.where(security_id: security_id).where("qty > 0").select(:id))
    before_sale = acquisitions
      .where("(entries.date, entries.created_at) <= (:date, :created_at)",
             date: entry.date, created_at: entry.created_at || Time.current)
      .where.not(id: lots_emptied_before_sale)
    before_sale.or(acquisitions.where(id: attribute_in_database(:lot_source_entry_id))).chronological
  end

  class << self
    def build_name(type, qty, ticker)
      prefix = type == "buy" ? "Buy" : "Sell"
      "#{prefix} #{qty.to_d.abs} shares of #{ticker}"
    end
  end

  def unrealized_gain_loss
    return nil unless qty.positive?
    current_price = security.current_price
    return nil if current_price.nil?
    reward = non_cash_reward
    return nil if reward && reward.unit_price&.currency != current_price.currency

    current_value = current_price * qty.abs
    cost_basis = price_money * qty.abs + fee_money

    Trend.new(current: current_value, previous: cost_basis)
  end

  # Set by callers that list many sales: what this sale took from each lot, as
  # HoldingLotDisposal.readable_by_sale gives it, or nil where there is no
  # readable record and the basis comes from the holding snapshot. Clears the
  # memo, so a sale measured before the preload does not keep its old figure.
  def preloaded_lot_disposals=(value)
    @preloaded_lot_disposals = value
    remove_instance_variable(:@realized_gain_loss) if defined?(@realized_gain_loss)
  end

  # Set by callers that list many disposals, so the proceeds conversion below
  # reads one preloaded set instead of a query per foreign disposal. Keyed
  # `[from, to, date]`.
  #
  # NOT authoritative when a key is absent, unlike preloaded_holdings: a caller
  # that preloads rates without preloading holdings leaves the basis side
  # unknowable without a query, so the preload keys it on the account's
  # currency and a position carried in another one misses. Treating a miss as
  # "no rate" would exclude a disposal that is perfectly measurable, so it
  # falls back to the single lookup rather than to a wrong answer.
  def preloaded_exchange_rates=(value)
    @preloaded_exchange_rates = value
    remove_instance_variable(:@realized_gain_loss) if defined?(@realized_gain_loss)
    @realized_gain_unconvertible = false
  end

  # One query for every rate a set of disposals can need, instead of one per
  # disposal. The date set and the currency sets are each small; the product is
  # a superset of the pairs actually wanted, which is cheaper to fetch than to
  # describe pair by pair in SQL.
  def self.preload_exchange_rates(trades)
    return if trades.empty?

    wanted = trades.flat_map do |trade|
      from = trade.currency
      next [] if from.blank?

      # BOTH sides the conversion can target: the account's currency, which is
      # what a position is usually carried in, and the holding's own where the
      # caller preloaded holdings and it differs. The conversion targets the
      # currency of the holding `realized_gain_loss` selects, so keying only on
      # the account's left a GBP position in a USD account -- the shape this
      # method exists to serve -- missing the preload and paying a lookup per
      # disposal. Asking for a pair that turns out unused costs nothing: the
      # query already fetches the product of the three sets.
      [ trade.entry.account.currency, trade.preloaded_basis_currency ]
        .compact_blank
        .uniq
        .reject { |to| to == from }
        .map { |to| [ from, to, trade.entry.date ] }
    end

    if wanted.empty?
      trades.each { |trade| trade.preloaded_exchange_rates = {} }
      return
    end

    rates = ExchangeRate
      .where(
        from_currency: wanted.map(&:first).uniq,
        to_currency: wanted.map(&:second).uniq,
        date: wanted.map(&:third).uniq
      )
      .to_h { |rate| [ [ rate.from_currency, rate.to_currency, rate.date ], rate.rate ] }

    trades.each { |trade| trade.preloaded_exchange_rates = rates }
  end

  # Set by callers that list many sales: the holdings this sale's basis is read
  # from. Authoritative once set, so an empty list means there is no position
  # to measure against, not that one should be looked up.
  def preloaded_holdings=(value)
    @preloaded_holdings = value
    remove_instance_variable(:@realized_gain_loss) if defined?(@realized_gain_loss)
  end

  # Each disposal's basis position, for a whole set in one query: per trade,
  # its security's latest holding on or before the trade date. Loading the
  # accounts' holdings instead reads a row per security per day of their whole
  # history, which on a long-lived brokerage account is hundreds of thousands.
  # A same-day tie (another currency, as a security remap can leave) resolves
  # as basis_holding does: the account's currency, then the lower id.
  def self.preload_basis_holdings(trades)
    return if trades.empty?

    wanted = [ trades.map { |t| t.entry.id }, trades.map { |t| t.entry.account_id },
               trades.map(&:security_id), trades.map { |t| t.entry.date } ]
    holdings = Holding.find_by_sql([ <<~SQL.squish, *wanted ])
      SELECT basis.*, wanted.entry_id AS basis_for_entry_id
      FROM unnest(ARRAY[?]::uuid[], ARRAY[?]::uuid[], ARRAY[?]::uuid[], ARRAY[?]::date[])
        AS wanted(entry_id, account_id, security_id, date)
      CROSS JOIN LATERAL (
        SELECT holdings.* FROM holdings
        JOIN accounts ON accounts.id = holdings.account_id
        WHERE holdings.account_id = wanted.account_id
          AND holdings.security_id = wanted.security_id
          AND holdings.date <= wanted.date
        ORDER BY holdings.date DESC, (holdings.currency = accounts.currency) DESC, holdings.id
        LIMIT 1
      ) AS basis
    SQL

    # A sale is measured against its holding's average cost, which for a
    # position without a stored basis is two or more queries each.
    Holding.preload_avg_costs(holdings)

    by_entry = holdings.index_by { |holding| holding["basis_for_entry_id"] }
    trades.each { |trade| trade.preloaded_holdings = Array(by_entry[trade.entry.id]) }
  end

  # The currency this disposal's basis is carried in, where it can be answered
  # without a query. `Holding#avg_cost` is Money in the HOLDING's own currency,
  # which is not always the account's, and that is what the proceeds are
  # converted into. nil when holdings were not preloaded: the preloader above
  # must not issue the queries it exists to avoid.
  def preloaded_basis_currency
    return nil unless defined?(@preloaded_holdings)

    basis_holding&.currency
  end

  # Calculates realized gain/loss for sell trades based on avg_cost at time of sale
  # Returns nil for buy trades or when cost basis cannot be determined
  def realized_gain_loss
    return @realized_gain_loss if defined?(@realized_gain_loss)

    @realized_gain_unconvertible = false
    @realized_gain_loss = calculate_realized_gain_loss
  end

  # True when #realized_gain_loss is nil only because the proceeds' currency
  # has no usable rate into the basis currency for the disposal's day, as
  # opposed to a buy, a transfer or an unknown cost basis. A caller summing
  # gains counts these as left out.
  def realized_gain_unconvertible?
    realized_gain_loss
    @realized_gain_unconvertible
  end

  # Trades are always excluded from expense budgets
  # They represent portfolio management, not living expenses
  def excluded_from_budget?
    true
  end


  # The label for this trade once it is on the given side: Buy and Sell
  # follow the side, any other activity (Sweep In, Reinvestment...) is kept.
  def label_for_side(sell:)
    return investment_activity_label if investment_activity_label.present? && SIDE_LABELS.exclude?(investment_activity_label)

    Trade::CreateForm::SECURITY_TRADE_LABELS[sell ? "sell" : "buy"]
  end

  private

    # Acquisitions whose lot is now empty and was emptied before this sale:
    # no sale dated on or after it took anything from the lot.
    #
    # A transfer out consumes lots without recording a disposal, so once one
    # replays at or after this sale an empty lot no longer says when it was
    # emptied. Nothing is excluded then: a lot that turns out to be empty
    # falls back to the account's method when the sale replays.
    def lots_emptied_before_sale
      later_transfers_out = on_or_after_sale(
        entry.account.entries.where(entryable_type: "Trade",
          entryable_id: Trade.where(security_id: security_id, investment_activity_label: INTERNAL_MOVEMENT_LABELS)
                             .where("qty < 0").select(:id))
      )
      return HoldingLot.none.select(:source_entry_id) if later_transfers_out.exists?

      later_disposals = on_or_after_sale(
        HoldingLotDisposal.joins(:sale_entry).where(account_id: entry.account_id).where.not(lot_source_entry_id: nil)
      )
      HoldingLot.derived.where(account_id: entry.account_id, qty: 0)
        .where.not(source_entry_id: later_disposals.select(:lot_source_entry_id))
        .select(:source_entry_id)
    end

    # Entries replay by date, then in the order they were entered (see
    # Holding::PortfolioCache#trades), so a same-day entry made earlier has
    # already run by the time this sale does. `scope` must expose `entries`.
    def on_or_after_sale(scope)
      if entry.persisted?
        scope.where("(entries.date, entries.created_at, entries.id) >= (:date, :created_at, :id)",
                    date: entry.date, created_at: entry.created_at, id: entry.id)
      else
        scope.where("(entries.date, entries.created_at) >= (:date, :created_at)",
                    date: entry.date, created_at: Time.current)
      end
    end

    def exchange_rate_must_be_valid
      if extra&.dig("exchange_rate_invalid")
        errors.add(:exchange_rate, "must be a number")
      elsif exchange_rate.present?
        numeric_rate = Float(exchange_rate) rescue nil
        if numeric_rate.nil? || !numeric_rate.finite? || numeric_rate <= 0
          errors.add(:exchange_rate, "must be greater than 0")
        end
      end
    end

    # Only a disposal names a lot: an edit that turns it into a buy or an
    # internal movement lets the stored lot go. A lot named in the same edit
    # is left for lot_source_entry_must_be_a_lot_choice to refuse.
    def drop_lot_source_entry
      self.lot_source_entry_id = nil
    end

    def lot_source_entry_must_be_a_lot_choice
      errors.add(:lot_source_entry, :invalid) unless lot_choices.exists?(id: lot_source_entry_id)
    end

    # The position the disposal is measured against: the latest snapshot for
    # this security on or before the disposal's date.
    #
    # Uses preloaded holdings when the caller set them, and treats a
    # defined-but-empty preload as authoritative rather than falling back to a
    # query. The answer never depends on the order the caller's array happens
    # to be in: two snapshots on the latest date (another currency, as a
    # security remap can leave) resolve to the account's currency, then the
    # lower id, the same rule as Trade.preload_basis_holdings.
    # Not memoised: `realized_gain_loss` already is, and a memo here would hold
    # a holding selected before a caller set `@preloaded_holdings`.
    def basis_holding
      if defined?(@preloaded_holdings)
        candidates = (@preloaded_holdings || []).select { |h| h.security_id == security_id && h.date <= entry.date }
        latest = candidates.map(&:date).max
        tied = candidates.select { |h| h.date == latest }
        tied.one? ? tied.first : tied.min_by { |h| [ h.currency == entry.account.currency ? 0 : 1, h.id ] }
      else
        entry.account.holdings
          .where(security_id: security_id)
          .where("date <= ?", entry.date)
          .order(date: :desc)
          .order(Arel.sql(Holding.sanitize_sql_array([ "holdings.currency = ? DESC", entry.account.currency ])))
          .order(:id)
          .first
      end
    end

    def lot_disposals
      return @preloaded_lot_disposals if defined?(@preloaded_lot_disposals)

      HoldingLotDisposal.readable_by_sale([ self ])[entry.id]
    end

    # The cost of the lots this sale consumed, :unknown when one of them has
    # no cost, or nil when there is no record covering the whole sale.
    def disposed_lots_cost
      disposals = lot_disposals
      return nil if disposals.blank? || disposals.sum(BigDecimal("0"), &:qty) != qty.abs
      return :unknown if disposals.any? { |disposal| disposal.unit_cost.nil? }

      Money.new(disposals.sum(BigDecimal("0")) { |disposal| disposal.qty * disposal.unit_cost }, disposals.first.currency)
    end

    # The position's average on the sale's day, applied to the units sold.
    def snapshot_cost
      holding = basis_holding
      holding.avg_cost * qty.abs if holding&.avg_cost
    end

    def calculate_realized_gain_loss
      return nil unless sell?
      # Moving an asset to another account you own realises nothing. Without
      # this the cost basis is compared against the day's price and the
      # difference is booked as a gain the user never made.
      return nil if internal_movement?

      # Under fifo the snapshot is the open lots' mean after the sale, not the
      # cost of the lots it consumed, so without a record covering the sale the
      # gain is unknown rather than priced off the snapshot.
      cost_basis = disposed_lots_cost || (snapshot_cost unless entry.account.cost_basis_fifo?)

      return nil unless cost_basis.is_a?(Money)

      # A disposal's fee is what selling cost, so it comes off the proceeds.
      sale_proceeds = converted_to_basis_currency(price_money * qty.abs - fee_money, cost_basis.currency)

      # No rate for that day means the gain is unknown, not zero and not the
      # figure a rate of 1.0 would give.
      if sale_proceeds.nil?
        @realized_gain_unconvertible = true
        return nil
      end

      Trend.new(current: sale_proceeds, previous: cost_basis)
    end

    # The proceeds are priced in the security's currency; the basis is carried
    # in the one the position is held in. `Trend#value` is `current - previous`
    # and `Money#-` keeps the left operand's currency while taking the right
    # one's bare amount, so without this the two were subtracted as plain
    # numbers and the difference was then labelled with the disposal's
    # currency -- an error that scaled with the rate and changed sign either
    # side of parity.
    #
    # Converted in THIS direction, and not the other, because it is the
    # direction the data holds: MarketDataImporter's first required pair is
    # every entry currency against its account's, so a EUR disposal in a USD
    # account has a EUR->USD row for the day it happened, while USD->EUR is
    # only ever there by accident of another account.
    #
    # Exact date, exact direction, no parity fallback and no nearest-rate
    # lookback. A disposal happened on one known day; the rate for that day is
    # the rate, and its absence is a fact to report rather than a 1.0 nobody
    # can see.
    #
    # A rate that is present but not positive is absent for this purpose.
    # `ExchangeRate` validates presence only -- neither the model nor the
    # column requires a positive number -- so a provider or an import can leave
    # a 0 behind, and multiplying by it books the disposal as a total loss the
    # user never made. A negative one is worse: it flips the sign. Both are the
    # missing-rate case wearing a number, and reporting no figure is the whole
    # point of the paragraph above.
    def converted_to_basis_currency(proceeds, basis_currency)
      from = proceeds.currency.iso_code
      to = basis_currency.iso_code
      return proceeds if from == to

      rate = preloaded_rate(from, to) ||
             ExchangeRate.find_by(from_currency: from, to_currency: to, date: entry.date)&.rate
      return nil unless rate.to_d.positive?

      Money.new(proceeds.amount * rate, to)
    end

    def preloaded_rate(from, to)
      return nil unless defined?(@preloaded_exchange_rates)

      (@preloaded_exchange_rates || {})[[ from, to, entry.date ]]
    end
end
