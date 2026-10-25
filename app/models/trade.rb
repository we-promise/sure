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

  # Trade types for categorization
  def buy?
    qty.positive?
  end

  def sell?
    qty.negative?
  end

  # A negative quantity that left for another account you own. It looks exactly
  # like a sale — same sign, same shape — and only the label tells them apart.
  def internal_movement?
    INTERNAL_MOVEMENT_LABELS.include?(investment_activity_label)
  end

  # The acquisitions this sale can name as the lot it sold from: buys and
  # transfers-in of its security, in its account, that the replay applies
  # before it (Entry.chronological: an earlier date, or the same date and
  # entered first), leaving out a lot sales dated before it had already
  # emptied. Only a sale in an account that sells by fifo has any, since under
  # average a sale relieves every lot pro rata. The choice the sale already
  # holds is always among them, so an edit keeps it, and is replayed only
  # while it names a lot that is still open; a new choice must be open by then.
  def lot_choices
    return Entry.none unless sell? && !internal_movement? && entry&.account&.cost_basis_fifo?

    acquisitions = entry.account.entries
      .where(entryable_type: "Trade", entryable_id: Trade.where(security_id: security_id).where("qty > 0").select(:id))
    before_sale = acquisitions
      .where("entries.date < :date OR (entries.date = :date AND (entries.created_at, entries.id) < (:created_at, :id))",
             date: entry.date, created_at: entry.created_at || Time.current, id: entry.id || "ffffffff-ffff-ffff-ffff-ffffffffffff")
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

    @realized_gain_loss = calculate_realized_gain_loss
  end

  # Trades are always excluded from expense budgets
  # They represent portfolio management, not living expenses
  def excluded_from_budget?
    true
  end

  private

    # Acquisitions whose lot is now empty and was emptied before this sale:
    # no sale dated on or after it took anything from the lot.
    def lots_emptied_before_sale
      later_disposals = HoldingLotDisposal.joins(:sale_entry)
        .where(account_id: entry.account_id).where.not(lot_source_entry_id: nil)
        .where("entries.date >= ?", entry.date)
      HoldingLot.derived.where(account_id: entry.account_id, qty: 0)
        .where.not(source_entry_id: later_disposals.select(:lot_source_entry_id))
        .select(:source_entry_id)
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

    def lot_source_entry_must_be_a_lot_choice
      errors.add(:lot_source_entry, :invalid) unless lot_choices.exists?(id: lot_source_entry_id)
    end

    # The position the disposal is measured against: the latest snapshot for
    # this security on or before the disposal's date.
    #
    # Uses preloaded holdings when the caller set them, and treats a
    # defined-but-empty preload as authoritative rather than falling back to a
    # query. `select` + `max_by` rather than `find`, so the answer does not
    # depend on the order the caller's array happens to be in.
    # Not memoised: `realized_gain_loss` already is, and a memo here would hold
    # a holding selected before a caller set `@preloaded_holdings`.
    def basis_holding
      if defined?(@preloaded_holdings)
        (@preloaded_holdings || [])
          .select { |h| h.security_id == security_id && h.date <= entry.date }
          .max_by(&:date)
      else
        entry.account.holdings
          .where(security_id: security_id)
          .where("date <= ?", entry.date)
          .order(date: :desc)
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

      cost_basis = disposed_lots_cost || snapshot_cost

      return nil unless cost_basis.is_a?(Money)

      # A disposal's fee is what selling cost, so it comes off the proceeds.
      sale_proceeds = converted_to_basis_currency(price_money * qty.abs - fee_money, cost_basis.currency)

      # No rate for that day means the gain is unknown, not zero and not the
      # figure a rate of 1.0 would give.
      return nil if sale_proceeds.nil?

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
