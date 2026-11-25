class Holding < ApplicationRecord
  include Monetizable, Gapfillable

  monetize :amount

  # Cost basis source priority (higher = takes precedence)
  COST_BASIS_SOURCE_PRIORITY = {
    nil => 0,
    "provider" => 1,
    "calculated" => 2,
    "manual" => 3
  }.freeze

  COST_BASIS_SOURCES = %w[manual calculated provider].freeze

  belongs_to :account
  belongs_to :security
  belongs_to :account_provider, optional: true
  belongs_to :provider_security, class_name: "Security", optional: true

  validates :qty, :currency, :date, :price, :amount, presence: true
  validates :qty, :price, :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :external_id, uniqueness: { scope: :account_id }, allow_blank: true
  validates :cost_basis_source, inclusion: { in: COST_BASIS_SOURCES }, allow_nil: true

  scope :chronological, -> { order(:date) }
  scope :for, ->(security) { where(security_id: security).order(:date) }
  scope :with_locked_cost_basis, -> { where(cost_basis_locked: true) }
  scope :with_unlocked_cost_basis, -> { where(cost_basis_locked: false) }

  delegate :ticker, to: :security

  # Answers derived from the attributes go when a change to them is saved,
  # as on #reload: `changed?` is false again by then and cannot tell.
  after_save :forget_derived_answers

  def name
    security.name || ticker
  end

  def weight
    return nil unless amount
    return 0 if amount.zero?

    # Never divide by less than the holdings (this one included), so negative
    # cash cannot push a weight past 100%. As InvestmentStatement#weight_denominator.
    value = amount_in_account_currency
    denominator = [ account.balance, account.current_holdings_total, value ].max
    denominator.positive? ? value / denominator * 100 : 1
  end

  # The stored per-share cost when it is a real value:
  # - If locked (user-set), trust the value even if 0 (valid for airdrops)
  # - If worked out from the trades and lots, trust 0 too: a lot the user
  #   says cost nothing, or a buy at a price of 0
  # - Otherwise require positive since providers sometimes return 0 when unknown
  def known_cost_basis
    cost_basis if cost_basis.present? && (cost_basis_locked? || cost_basis.positive? || cost_basis_source == "calculated")
  end

  # Returns average cost per share, or nil if unknown.
  #
  # Uses pre-computed cost_basis if available (set during materialization),
  # otherwise falls back to calculating from trades. Returns nil when cost
  # basis cannot be determined (no trades and no provider cost_basis).
  def avg_cost
    # Use stored cost_basis if available (eliminates N+1 queries)
    return stored_avg_cost if known_cost_basis

    # A caller that has many holdings can compute the fallback for all of
    # them in one query and hand each its answer (.preload_avg_costs), so a
    # page that lists every position does not run calculate_avg_cost's two
    # queries per holding. nil is a valid preloaded answer: "unknown". It
    # answers for the attributes it was computed from, so a holding changed
    # since then computes its own.
    return @preloaded_avg_cost if defined?(@preloaded_avg_cost) && !changed?

    # Fallback to calculation for holdings without pre-computed cost_basis
    replayed_avg_cost
  end

  # known_cost_basis as average cost per share, or nil when there is none to
  # trust. Never queries, so a caller with a better fallback than replaying
  # through this holding's date (Trade#realized_gain_loss) can skip that replay.
  def stored_avg_cost
    Money.new(known_cost_basis, currency) if known_cost_basis
  end

  # The weighted-average cost of the position immediately before `entry`,
  # replayed from this security's trades as calculate_avg_cost does, or nil
  # when it is unknown. Realized gain prices a sale at this figure: average
  # cost does not move on a sale, but a sale that closes the position leaves
  # a row with nothing held and no basis, so `avg_cost` has no figure to give.
  #
  # Trades count when they sort strictly before `entry` in Entry.chronological
  # order, so a buy earlier the same day counts and the sale itself does not.
  # A split with an ex-date on or before the sale's date counts, since a split
  # applies at the open of its ex-date. Units a sale sells beyond the position
  # are priced at the acquisitions that cover them (.shortfall_cover_cost),
  # and the figure is the cost per unit across the whole sale.
  def avg_cost_before(entry)
    calculate_avg_cost(through: entry.date, before: entry)
  end

  # The avg-cost fallback for holdings in accounts that sell by fifo, by
  # holding id.
  # What a fifo position holds is its open lots, not a share of every
  # purchase, so the figure is their mean, as Holding::LotBook#average_cost
  # gives it; the opening lot stays out, as it does there. The stored lots
  # are the position as it stands, so they answer only for its latest row,
  # and only while they add up to it (HoldingLot.in_partition). Any other
  # row, or an open lot with no cost, is unknown: the trades' pooled average
  # is the average method's figure, not this one.
  def self.fifo_avg_costs(holdings)
    open_lots = open_lots_for(holdings)

    holdings.to_h do |holding|
      open = open_lots[holding.id]&.reject(&:opening?)
      value = if open&.any? && open.none? { |lot| lot.unit_cost.nil? }
        Money.new(open.sum { |lot| lot.qty * lot.unit_cost } / open.sum(&:qty), holding.currency)
      end
      [ holding.id, value ]
    end
  end

  # Each holding's open lots, by holding id, the opening lot first and then by
  # acquisition: an array for the position's latest row while its stored lots
  # add up to it (HoldingLot.in_partition), and nil for any other row, since
  # the lots are the position as it stands. Four queries for any number of
  # holdings.
  def self.open_lots_for(holdings)
    return {} if holdings.empty?

    account_ids = holdings.map(&:account_id).uniq
    security_ids = holdings.map(&:security_id).uniq
    readable = HoldingLot.in_partition(account_ids, security_ids)
    latest = Holding.where(account_id: account_ids, security_id: security_ids).group(:account_id, :security_id).maximum(:date)
    lots = HoldingLot.where(account_id: account_ids, security_id: security_ids).where("holding_lots.qty > 0")
      .left_joins(:source_entry).select("holding_lots.*, entries.entryable_id AS trade_id")
      .order(Arel.sql("holding_lots.acquired_on ASC NULLS FIRST"), "holding_lots.created_at")
      .group_by { |lot| [ lot.account_id, lot.security_id ] }

    holdings.to_h do |holding|
      key = [ holding.account_id, holding.security_id ]
      [ holding.id, (lots.fetch(key, []) if readable.include?(key) && latest[key] == holding.date) ]
    end
  end

  # #calculate_avg_cost for every holding given: the same trades, read through
  # the same SQL (.avg_cost_row_sql), replayed by the same code
  # (.replay_avg_cost), with the same lot rules (a clamped position has no
  # cost; a fifo one reads its open lots, all of them together through
  # .fifo_avg_costs), so the batch cannot answer differently from the
  # holding on its own. The trades of every holding come back in one query and
  # the splits in another, however many holdings there are. Holdings with a
  # stored cost basis are skipped, since #avg_cost never reaches the fallback
  # for them. So are holdings with unsaved changes, unsaved ones included: the
  # query reads the stored row, which is not what they hold.
  def self.preload_avg_costs(holdings)
    pending = holdings.reject { |holding| holding.known_cost_basis || holding.changed? }
    return if pending.empty?

    unit_cost, internal_movement = avg_cost_row_sql(holding_currency: "cur.currency", account_currency: "accounts.currency")
    lot_joins = avg_cost_lot_joins_sql(holding_currency: "cur.currency", account_currency: "accounts.currency", holding_date: "cur.date")
    rows = Holding.from("holdings cur")
      .joins(<<~SQL.squish)
        JOIN accounts ON accounts.id = cur.account_id
        JOIN entries ON entries.account_id = cur.account_id
          AND entries.entryable_type = 'Trade'
          AND entries.date <= cur.date
        JOIN trades ON trades.id = entries.entryable_id AND trades.security_id = cur.security_id
        LEFT JOIN exchange_rates ON (
          exchange_rates.date = entries.date AND
          exchange_rates.from_currency = trades.currency AND
          exchange_rates.to_currency = cur.currency
        )
      SQL
      .joins(lot_joins)
      .where("cur.id IN (?)", pending.map(&:id))
      .reorder(Arel.sql("cur.id, #{AVG_COST_REPLAY_ORDER}"))
      .pluck(Arel.sql("cur.id"), Arel.sql("entries.date"), Arel.sql("trades.qty"), Arel.sql(unit_cost), Arel.sql(internal_movement),
             Arel.sql("accounts.cost_basis_method = 'fifo'"), Arel.sql(<<~SQL.squish))
               EXISTS (
                 SELECT 1 FROM holding_lots clamped_lots
                 WHERE clamped_lots.account_id = cur.account_id
                   AND clamped_lots.security_id = cur.security_id
                   AND clamped_lots.clamped
               )
             SQL
      .group_by(&:first)

    # A holding with no trades has nothing to replay, so its splits are not read.
    traded = pending.select { |holding| rows.key?(holding.id) }
    splits = traded.empty? ? {} : Security::Split.where(security_id: traded.map(&:security_id).uniq, ex_date: ..traded.map(&:date).max)
      .order(:ex_date).to_a.group_by(&:security_id)

    # The account decides fifo. A holding with no row (no buy dated on or
    # before it, as with a provider row that predates its trade) still reads
    # its lots, so its account is looked up; nothing extra runs otherwise.
    unrowed = pending.reject { |holding| rows.key?(holding.id) }
    fifo_account_ids = unrowed.any? ? Account.where(id: unrowed.map(&:account_id).uniq, cost_basis_method: "fifo").pluck(:id).to_set : Set.new
    lot_costs = fifo_avg_costs(pending.select { |holding| rows.key?(holding.id) ? rows[holding.id].first[5] : fifo_account_ids.include?(holding.account_id) })

    pending.each do |holding|
      holding_rows = rows.fetch(holding.id, [])
      value = if holding_rows.first&.last
        nil
      elsif lot_costs.key?(holding.id)
        lot_costs[holding.id]
      else
        trade_rows = holding_rows.map { |row| row[1..4] + [ true ] }
        replay_avg_cost(trade_rows, splits.fetch(holding.security_id, []).select { |split| split.ex_date <= holding.date },
                        qty: holding.qty, date: holding.date, through: holding.date, currency: holding.currency)
      end
      holding.preload_avg_cost(value)
    end
  end

  # The order the calculators replay trades in (Holding::PortfolioCache#trades):
  # by date, then as entered, and a buy before a sale entered with it, as an
  # import stamps a day's trades with one created_at; then by id.
  AVG_COST_REPLAY_ORDER = "entries.date ASC, entries.created_at ASC, (trades.qty < 0) ASC, entries.id ASC".freeze

  # The per-trade columns the replay reads, as SQL over `trades`, `entries` and
  # an `exchange_rates` row joined for the trade's day into the holding's
  # currency: the unit cost in the holding's currency, fee included on a
  # purchase (Holding::TradeCalculatorHelpers#effective_trade_price), or NULL
  # when a foreign trade has no usable rate; and whether it is an internal
  # movement. `holding_currency` and `account_currency` are SQL expressions.
  # The query also joins .avg_cost_lot_joins_sql: a trade whose lot the user
  # has costed counts at that cost, a transfer in included, so it is no
  # internal movement here.
  #
  # The rate a trade carries itself (extra["exchange_rate"], e.g. IBKR's
  # fx_rate_to_base) comes before the table's, as in the calculators and
  # Balance::SyncCache, but it is into the account's currency, so it only
  # applies to a holding in that currency; one a provider holds in another
  # currency converts at the table's rate alone. A rate written to `extra`
  # directly can be a plain decimal string, which Trade's validation and
  # Money#exchange_to both accept, so that counts too; anything else, an
  # exponent or an absurd length included, is not cast. A number is held to 20
  # integer digits by size, so multiplying it by the price cannot overflow the
  # query. A rate of zero or less converts nothing, so it counts as missing.
  def self.avg_cost_row_sql(holding_currency:, account_currency:)
    own_rate = <<~SQL.squish
      CASE jsonb_typeof(trades.extra->'exchange_rate')
        WHEN 'number' THEN CASE WHEN abs((trades.extra->>'exchange_rate')::numeric) < 1e20
                                THEN (trades.extra->>'exchange_rate')::numeric END
        WHEN 'string' THEN CASE WHEN trades.extra->>'exchange_rate' ~ '^[[:space:]]*[+-]?([0-9]{1,20}([.][0-9]{0,20})?|[.][0-9]{1,20})[[:space:]]*$'
                                THEN (trades.extra->>'exchange_rate')::numeric END
      END
    SQL
    rate = "CASE WHEN #{holding_currency} = #{account_currency} THEN COALESCE(#{own_rate}, exchange_rates.rate) ELSE exchange_rates.rate END"
    factor = "CASE WHEN trades.currency <> #{holding_currency} THEN CASE WHEN #{rate} > 0 THEN #{rate} END ELSE 1 END"
    lot_factor = "CASE WHEN #{holding_currency} = #{account_currency} THEN 1 WHEN lot_rates.rate > 0 THEN lot_rates.rate END"
    unit_cost = <<~SQL.squish
      CASE
        WHEN lots.id IS NOT NULL THEN lots.manual_total_cost / trades.qty * #{lot_factor}
        WHEN trades.qty > 0 THEN (trades.price + COALESCE(trades.fee, 0) / trades.qty) * #{factor}
      END
    SQL
    internal_movement = sanitize_sql_array([ "COALESCE(trades.investment_activity_label IN (?), FALSE) AND lots.id IS NULL", Trade::INTERNAL_MOVEMENT_LABELS ])

    [ unit_cost, internal_movement ]
  end

  # The joins .avg_cost_row_sql reads a costed lot through: `lots`, the lot an
  # acquisition opened when the user has set what it cost, and `lot_rates`,
  # the rate on the acquisition's day from the account's currency, which the
  # cost is in, into the holding's. A cost basis is what was paid then, so a
  # lot in a holding of another currency converts at that day's rate, and is
  # unknown without one. A cost set on a lot that a split has restated since
  # its acquisition is not used. All three arguments are SQL expressions.
  def self.avg_cost_lot_joins_sql(holding_currency:, account_currency:, holding_date:)
    <<~SQL.squish
      LEFT JOIN holding_lots lots ON lots.account_id = entries.account_id
        AND lots.source_entry_id = entries.id
        AND lots.manual_total_cost IS NOT NULL
        AND trades.qty > 0
        AND NOT EXISTS (
          SELECT 1 FROM security_splits lot_splits
          WHERE lot_splits.security_id = trades.security_id
            AND lot_splits.ex_date > entries.date
            AND lot_splits.ex_date <= #{holding_date}
        )
      LEFT JOIN exchange_rates lot_rates ON (
        lot_rates.date = entries.date AND
        lot_rates.from_currency = #{account_currency} AND
        lot_rates.to_currency = #{holding_currency}
      )
    SQL
  end

  # Replacing the cost replaces the #trend derived from it.
  def preload_avg_cost(value)
    @preloaded_avg_cost = value
    remove_instance_variable(:@trend) if defined?(@trend)
  end

  # A reload replaces the attributes, so an answer computed from the old ones
  # must go with them -- including #trend, which is derived from avg_cost,
  # and #day_change, which is derived from amount and date.
  def reload(*)
    forget_derived_answers
    super
  end

  def trend
    @trend ||= calculate_trend
  end

  # Day change based on previous holding snapshot (same account/security/currency)
  # Returns a Trend struct similar to other trend usages or nil if no prior snapshot.
  def day_change
    # Memoize even when nil to avoid repeated queries during a request lifecycle
    return @day_change if instance_variable_defined?(:@day_change)

    return (@day_change = nil) unless amount_money

    prev = account.holdings
                 .where(security_id: security_id, currency: currency)
                 .where("date < ?", date)
                 .order(date: :desc)
                 .first

    @day_change = prev&.amount_money ? Trend.new(current: amount_money, previous: prev.amount_money) : nil
  end

  def trades
    account.entries.where(entryable: account.trades.where(security: security)).reverse_chronological
  end

  def destroy_holding_and_entries!
    transaction do
      account.entries.where(entryable: account.trades.where(security: security)).destroy_all
      destroy
    end

    account.sync_later
  end

  # Returns the priority level for the current source (higher = better)
  def cost_basis_source_priority
    COST_BASIS_SOURCE_PRIORITY[cost_basis_source] || 0
  end

  # Check if this holding's cost_basis can be overwritten by the given source
  def cost_basis_replaceable_by?(new_source)
    return false if cost_basis_locked?

    new_priority = COST_BASIS_SOURCE_PRIORITY[new_source] || 0

    # Special case: when user unlocks a manual cost_basis, they're opting into
    # recalculation. Allow only "calculated" source to replace it (from trades).
    # This is the whole point of the unlock action.
    if cost_basis_source == "manual"
      return new_source == "calculated"
    end

    # Allow refreshes from the same source (e.g., new trades change calculated cost basis,
    # or providers send updated cost basis).
    new_priority >= cost_basis_source_priority
  end

  # The position's open lots, the opening lot first and then by acquisition.
  # The stored lots are the position as it stands, so only its latest row
  # shows them, and only while they add up to it (HoldingLot.in_partition).
  def open_lots
    return HoldingLot.none unless date == account.holdings.where(security_id: security_id).maximum(:date)
    return HoldingLot.none unless HoldingLot.in_partition([ account_id ], [ security_id ]).include?([ account_id, security_id ])

    HoldingLot.where(account_id: account_id, security_id: security_id).where("qty > 0")
      .order(Arel.sql("acquired_on ASC NULLS FIRST"), :created_at)
  end

  # Whether the provider supplies the position's cost: its latest row, the one
  # its lots describe, holds a provider's figure. Restatement leaves a
  # provider's rows alone, so a lot cost set under it would change nothing the
  # position shows.
  def provider_cost_position?
    latest = account.holdings.where(security_id: security_id).order(date: :desc, id: :asc).first
    latest.present? && latest.cost_basis_source == "provider" && latest.known_cost_basis.present?
  end

  # Set cost_basis from user input (locks the value)
  def set_manual_cost_basis!(value)
    update!(
      cost_basis: value,
      cost_basis_source: "manual",
      cost_basis_locked: true
    )
  end

  # Unlock cost_basis to allow provider/calculated updates
  def unlock_cost_basis!
    update!(cost_basis_locked: false)
  end

  # Check if this holding's security can be changed by provider sync
  def security_replaceable_by_provider?
    !security_locked?
  end

  # Check if user has remapped this holding to a different security
  # Also verifies the provider_security record still exists (FK should prevent deletion, but be safe)
  def security_remapped?
    provider_security_id.present? && security_id != provider_security_id && provider_security.present?
  end

  # Remap this holding (and all other holdings for the same security) to a different security
  # Also moves all trades for the old security to the new security
  # If the target security already has holdings on some dates, merge by combining qty/amount
  def remap_security!(new_security)
    return if new_security.id == security_id

    old_security = security

    transaction do
      # Find (date, currency) pairs where the new security already has holdings (collision keys)
      # Currency must match to merge - can't combine holdings denominated in different currencies
      collision_keys = account.holdings
        .where(security: new_security)
        .where(date: account.holdings.where(security: old_security).select(:date))
        .pluck(:date, :currency)
        .to_set

      # Process each holding for the old security
      account.holdings.where(security: old_security).find_each do |holding|
        if collision_keys.include?([ holding.date, holding.currency ])
          # Collision: merge into existing holding for new_security (same date AND currency)
          existing = account.holdings.find_by!(security: new_security, date: holding.date, currency: holding.currency)
          merged_qty = existing.qty + holding.qty
          merged_amount = existing.amount + holding.amount

          # Calculate weighted average cost basis if both holdings have cost_basis
          merged_cost_basis = if existing.cost_basis.present? && holding.cost_basis.present? && merged_qty.positive?
            ((existing.cost_basis * existing.qty) + (holding.cost_basis * holding.qty)) / merged_qty
          else
            existing.cost_basis # Keep existing if we can't calculate weighted average
          end

          # Preserve provider tracking from the holding being destroyed
          # so subsequent syncs can find the merged holding
          merge_attrs = {
            qty: merged_qty,
            amount: merged_amount,
            price: merged_qty.positive? ? merged_amount / merged_qty : 0,
            cost_basis: merged_cost_basis
          }
          merge_attrs[:external_id] ||= holding.external_id if existing.external_id.blank? && holding.external_id.present?
          merge_attrs[:provider_security_id] ||= holding.provider_security_id || old_security.id if existing.provider_security_id.blank?
          merge_attrs[:account_provider_id] ||= holding.account_provider_id if existing.account_provider_id.blank? && holding.account_provider_id.present?
          merge_attrs[:security_locked] = true # Lock merged holding to prevent provider overwrites

          existing.update!(merge_attrs)
          holding.destroy!
        else
          # No collision: update to new security
          holding.provider_security_id ||= old_security.id
          holding.security = new_security
          holding.security_locked = true
          holding.save!
        end
      end

      # Move all trades for old security to new security, and their lots
      account.trades.where(security: old_security).update_all(security_id: new_security.id)
      lots = account.holding_lots.where(security: old_security)
      HoldingLot.move!(derived: lots.derived, opening: lots.opening, to: new_security)
    end

    # Reload self to reflect changes (may raise RecordNotFound if self was destroyed)
    begin
      reload
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  # Reset security (and all related holdings) back to what the provider originally sent
  # Note: This moves ALL trades for current_security back to original_security. If the user
  # had legitimate trades for the target security before remapping, those would also be moved.
  # In practice this is rare since SimpleFIN doesn't provide trades, and Plaid trades would
  # typically be for real tickers not CUSTOM: ones. A more robust solution would track which
  # trades were moved during remap, but that adds significant complexity for an edge case.
  def reset_security_to_provider!
    return unless provider_security_id.present?

    current_security = security
    original_security = provider_security

    # Guard against deleted provider_security (shouldn't happen due to FK, but be safe)
    return unless original_security.present?

    transaction do
      # Move trades back (see note above about limitation)
      account.trades.where(security: current_security).update_all(security_id: original_security.id)
      lots = account.holding_lots.where(security: current_security)
      HoldingLot.move!(derived: lots.derived, opening: lots.opening.where(origin_security: original_security), to: original_security)

      # Reset ALL holdings that were remapped from this provider_security
      account.holdings.where(security: current_security, provider_security: original_security).find_each do |holding|
        holding.update!(
          security: original_security,
          security_locked: false,
          provider_security_id: nil
        )
      end
    end

    # Reload self to reflect changes
    reload
  end

  # Check if cost_basis is known (has a source and positive value)
  def cost_basis_known?
    cost_basis.present? && cost_basis.positive? && cost_basis_source.present?
  end

  # Human-readable source label for UI display
  def cost_basis_source_label
    return nil unless cost_basis_source.present?

    I18n.t("holdings.cost_basis_sources.#{cost_basis_source}")
  end

  # The replay #calculate_avg_cost and .preload_avg_costs share: walks `rows`
  # ([date, qty, unit cost, internal movement?, replayed?], oldest first in
  # AVG_COST_REPLAY_ORDER) and `splits` (ex-date order) as the calculators do,
  # starting from the position the rows do not explain, and returns the
  # average cost in `currency`, or nil when it is unknown. With `sale_qty`,
  # the units sold by the first row not replayed, the figure is that sale's
  # cost per unit: the average for the units held and the covering
  # acquisitions' cost for the rest.
  def self.replay_avg_cost(rows, all_splits, qty:, date:, through:, currency:, sale_qty: nil)
    book = Holding::LotBook.new
    transferred = false
    position = opening_position(rows, all_splits, qty: qty, date: date)
    # The opening position and each transfer in are lots of unknown cost, as
    # the calculators book them, so a sale from them relieves units the book
    # holds rather than leaving a shortfall the next buy would fill.
    book.add_unknown(position)
    splits, later_splits = all_splits.partition { |split| split.ex_date <= through }

    apply_splits = lambda do |up_to|
      while splits.any? && splits.first.ex_date <= up_to
        ratio = splits.shift.ratio
        book.split(ratio)
        position = Security::Split.scale(position, ratio)
      end
    end

    rows.each do |trade_date, trade_qty, unit_cost, internal_movement, replayed|
      break unless replayed

      apply_splits.call(trade_date)
      previous_position = position

      # Units moved in were acquired at a price nothing here knows -- a coin
      # bought at 30k and moved in at 60k would report no gain -- so they
      # make the whole position's cost unknown. Units moved out are relieved
      # at the running average, like a sell.
      if internal_movement && trade_qty.positive?
        transferred = true
        book.add_unknown(trade_qty)
      else
        book.apply(unit_cost, trade_qty)
      end

      position += trade_qty
      # Only a genuine downward crossing through zero clears the mark, as in
      # the calculators: a position that was never positive held no units.
      transferred = false if previous_position.positive? && position <= 0
    end
    apply_splits.call(through)

    average = book.average_cost unless transferred
    held = [ sale_qty, book.open_qty ].min if sale_qty
    if held && held < sale_qty
      return nil if held.positive? && average.nil?

      cover = shortfall_cover_cost(rows.drop_while { |row| row[4] }.drop(1), later_splits,
                                   ahead: book.shortfall, short: sale_qty - held)
      return nil unless cover

      average = ((average || 0) * held + cover) / sale_qty
    end
    return nil unless average

    # Rounded to the scale `cost_basis` is stored at, so the figure is the one
    # the next materialization writes, not one a per-unit fee leaves at
    # 214.99999... when the stored basis reads 215. A cost too small for that
    # scale keeps its precision rather than rounding to a free position.
    rounded = average.round(columns_hash["cost_basis"].scale)
    Money.new(rounded.zero? && !average.zero? ? average : rounded, currency)
  end

  # What `short` units sold beyond the position cost, priced as
  # Holding::LotBook prices a fifo sale's shortfall (#add_lot and #cover): the
  # acquisitions in `rows`, those after the sale, fill the oldest shortfall
  # first, `ahead` being what earlier sales left uncovered, each at its own
  # cost. nil when an acquisition that covers it has no known cost (a transfer
  # in, a buy with no rate), when a split comes first (#split: a cover after
  # it is in other shares), or when the rows never cover it all.
  def self.shortfall_cover_cost(rows, splits, ahead:, short:)
    cost = BigDecimal("0")
    rows.each do |trade_date, trade_qty, unit_cost, internal_movement|
      return nil if splits.any? { |split| split.ex_date <= trade_date }
      next unless trade_qty.positive?

      ahead_filled = [ trade_qty, ahead ].min
      ahead -= ahead_filled
      filled = [ trade_qty - ahead_filled, short ].min
      next unless filled.positive?
      return nil if internal_movement || unit_cost.nil?

      cost += filled * unit_cost
      short -= filled
      return cost if short.zero?
    end
    nil
  end

  # The position held before the first of `rows`: this holding's quantity
  # with every trade and split up to its date undone, latest first. A split
  # applies at the open of its ex-date, so it is undone after that day's
  # trades.
  def self.opening_position(rows, splits, qty:, date:)
    position = qty.to_d
    pending = splits.select { |split| split.ex_date <= date }

    rows.reverse_each do |trade_date, trade_qty|
      next if trade_date > date

      position = Security::Split.unscale(position, pending.pop.ratio) while pending.any? && pending.last.ex_date > trade_date
      position -= trade_qty
    end
    pending.reverse_each { |split| position = Security::Split.unscale(position, split.ratio) }

    position
  end

  private
    def forget_derived_answers
      remove_instance_variable(:@replayed_avg_cost) if defined?(@replayed_avg_cost)
      remove_instance_variable(:@preloaded_avg_cost) if defined?(@preloaded_avg_cost)
      remove_instance_variable(:@trend) if defined?(@trend)
      remove_instance_variable(:@day_change) if defined?(@day_change)
    end

    def amount_in_account_currency(unconvertible: amount)
      return amount if currency == account.currency

      Money.new(amount, currency).exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      unconvertible
    end
    public :amount_in_account_currency

    def calculate_trend
      return nil unless amount_money
      return nil if avg_cost.nil? # Can't calculate trend without cost basis (0 is valid for airdrops)

      start_amount = qty * avg_cost

      Trend.new \
        current: amount_money,
        previous: start_amount
    end

    # calculate_avg_cost through this holding's date, once per instance, nil
    # included: a page asks a holding for its average cost several times, and
    # each answer would replay the whole history. Only this default cut-off is
    # kept; avg_cost_before replays to its own.
    def replayed_avg_cost
      return @replayed_avg_cost if defined?(@replayed_avg_cost)

      @replayed_avg_cost = calculate_avg_cost
    end

    # The weighted-average cost of the position on this holding's date, worked
    # out from the trades the way the holding calculators work it out
    # (Holding::ForwardCalculator#apply_trades), so a holding with no stored
    # basis shows the figure the next materialization would store: sells are
    # relieved at the running average, a split rescales the position at the
    # open of its ex-date, and a transfer in makes the cost unknown until the
    # position is closed. Returns nil when the cost is unknown.
    #
    # `through` is the last day replayed, the holding's own date by default.
    # `before`, an entry on that day, stops the replay just short of it
    # (avg_cost_before).
    #
    # The replay starts from the position the trades do not explain, as
    # Holding::ReverseCalculator#precompute_cost_basis seeds it from the
    # provider's snapshot: a reverse-synced account can hold shares from
    # before its first imported trade, and a sale that empties the imported
    # trades then leaves those still held, so a transfer among them stays
    # unknown. This holding's quantity, walked back through the trades and
    # splits up to its date, is that opening position; for a forward-synced
    # or manual account it is zero.
    #
    # Two lot rules come first. A clamped position holds fewer units than the
    # trades bought (see Holding::ReverseCalculator), so no figure drawn from
    # those trades is its cost. A fifo position holds its open lots
    # (.fifo_avg_costs), which are the position as it stands, so they say
    # nothing about the cost just before an earlier sale, and the trades'
    # pooled average is the average method's figure, not fifo's.
    def calculate_avg_cost(through: date, before: nil)
      return nil if HoldingLot.where(account_id: account_id, security_id: security_id, clamped: true).exists?
      return before ? nil : self.class.fifo_avg_costs([ self ])[id] if account.cost_basis_fifo?

      splits = Security::Split.where(security_id: security_id).order(:ex_date)
      splits = splits.where(ex_date: ..[ through, date ].max) unless before
      sale_qty = -before.entryable.qty if before && before.entryable.try(:qty).to_d.negative?
      self.class.replay_avg_cost(avg_cost_trade_rows(through: through, before: before), splits.to_a,
                                 qty: qty, date: date, through: through, currency: currency, sale_qty: sale_qty)
    end

    # This security's trades up to this holding's date and up to the replay's
    # cutoff -- `through`, or strictly before the entry `before` in the same
    # order -- oldest first in AVG_COST_REPLAY_ORDER, as
    # [date, qty, unit cost, internal movement?, replayed?] (see
    # .avg_cost_row_sql). Both sets are a prefix of that order, so the replayed
    # rows lead and one query serves the walk back to the opening position and
    # the replay. With `before`, the trades after it come too, since what
    # covers a sale beyond the position comes later.
    def avg_cost_trade_rows(through:, before:)
      quoted = { holding_currency: self.class.connection.quote(currency), account_currency: self.class.connection.quote(account.currency) }
      unit_cost, internal_movement = self.class.avg_cost_row_sql(**quoted)
      lot_joins = self.class.avg_cost_lot_joins_sql(**quoted, holding_date: self.class.connection.quote(date))

      cutoff = ActiveRecord::Base.sanitize_sql_array(
        if before
          # A row comparison, so it sorts exactly as AVG_COST_REPLAY_ORDER does.
          [ "(entries.date, entries.created_at, (trades.qty < 0), entries.id) < (?, ?, ?, ?)",
            before.date, before.created_at, before.entryable.try(:qty).to_d.negative?, before.id ]
        else
          [ "entries.date <= ?", through ]
        end
      )

      account.trades
        .with_entry
        .joins(ActiveRecord::Base.sanitize_sql_array([
          "LEFT JOIN exchange_rates ON (
            exchange_rates.date = entries.date AND
            exchange_rates.from_currency = trades.currency AND
            exchange_rates.to_currency = ?
          )", currency
        ]))
        .joins(lot_joins)
        .where(security_id: security_id)
        .then { |trades| before ? trades : trades.where("(#{cutoff}) OR entries.date <= ?", date) }
        .reorder(Arel.sql(AVG_COST_REPLAY_ORDER))
        .pluck(Arel.sql("entries.date"), Arel.sql("trades.qty"), Arel.sql(unit_cost), Arel.sql(internal_movement), Arel.sql("COALESCE(#{cutoff}, FALSE)"))
    end
end
