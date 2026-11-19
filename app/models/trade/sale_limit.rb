# Stops a sale from taking a position below zero.
#
# A sale on day D removes units from D onward, so it is allowed only if the
# position without it covers the sale on every day from D through today, or
# through the last future-dated trade (a split after D scales both sides,
# including one announced for a future date). That way a back-dated sale
# cannot push a later day below zero either. The position comes from the
# calculator the account sync uses, so splits count the way they do on the
# holdings tab.
#
# Linked accounts follow the same rule, but there the provider's holdings are
# the truth from today backwards: a sale recorded by hand only raises the days
# before it and can never take a day below zero, so it is never refused.
#
# Only the places where a person records or changes a sale run this check
# (trade form, API, converting a transaction, bulk edit). Imports and provider
# syncs describe what already happened elsewhere and are not checked; a
# position they take below zero shows up as a warning on the holdings tab.
class Trade::SaleLimit
  attr_reader :entry

  # Checks and saves under a lock on the account, so two sales at the same
  # moment cannot both count the same units as available. Any trade takes the
  # lock, a purchase too: moving a purchase later while a sale is checked
  # would let the sale count units that are no longer there on its date.
  # Ordinary transactions and trades on linked accounts stay lock-free.
  def self.save(entry)
    entry.account.transaction do
      limit = new(entry)
      limit.lock_account
      limit.validate && entry.save
    end
  end

  # For a bulk edit: locks the account and decides whether the sale needs a
  # check, before the entry is saved. Call #validate once the whole batch is
  # saved, so each sale is checked against the batch's final state.
  def self.prepare(entry)
    limit = new(entry)
    limit.lock_account
    limit.checks?
    limit
  end

  def initialize(entry)
    @entry = entry
  end

  # Adds an error to the entry and returns false when the sale is too large.
  def validate
    return true unless checks?
    return true if fits?

    entry.errors.add(:base, error_message)
    false
  end

  # The most this sale may remove, in units on the sale date. Never below zero.
  def available_qty
    @available_qty ||= [ limiting_day.last, 0 ].max
  end

  # Takes the account lock when this entry needs it. A sale field this request
  # leaves alone is then read again: another request may have changed it while
  # this one waited, and a save writes only the changed fields, so the check
  # has to see the date, quantity and security that end up stored together.
  def lock_account
    return unless guards_account?

    account.lock!
    refresh_unchanged_fields
  end

  # Whether saving this entry can change what a sale on the same account may
  # remove, so it has to be serialized with sales being checked.
  def guards_account?
    trade.is_a?(Trade) && account.present? && !account.linked?
  end

  # Whether this entry is a sale (or worsens one) that the limit applies to.
  # Decided once, before the entry is saved: a bulk edit saves the whole batch
  # first and validates afterwards.
  def checks?
    return @checks unless @checks.nil?

    @checks = trade.is_a?(Trade) && security.present? && account.present? && entry.date.present? &&
      trade.qty.to_d.negative? && !security.cash? && !account.linked? &&
      (entry.new_record? || worsens_existing_sale?)
  end

  private
    def trade
      entry.entryable
    end

    def account
      entry.account
    end

    def security
      trade.security
    end

    def sold_qty
      trade.qty.to_d.abs
    end

    def refresh_unchanged_fields
      refresh_unchanged(entry, Entry.unscoped, %w[date])
      refresh_unchanged(trade, Trade, %w[qty security_id])
    end

    def refresh_unchanged(record, scope, fields)
      return unless record.persisted?

      unchanged = fields.reject { |field| record.attribute_changed?(field) }
      return if unchanged.empty?

      stored = scope.where(id: record.id).pick(*unchanged)
      return if stored.nil?

      Array(stored).zip(unchanged).each do |value, field|
        record[field] = value
        record.clear_attribute_changes([ field ])
      end
    end

    # An edit that only makes an existing sale smaller cannot take the position
    # lower than it already was, so it is not checked. That keeps old data,
    # which may already be oversold, editable (notes, price, a smaller qty).
    # Compares with the stored row, read after the account lock, so an edit
    # made meanwhile by another request is not missed.
    def worsens_existing_sale?
      stored_date = Entry.unscoped.where(id: entry.id).pick(:date)
      stored_qty, stored_security_id = Trade.where(id: trade.id).pick(:qty, :security_id)
      return true if stored_date.nil? || stored_qty.nil? || !stored_qty.to_d.negative?

      entry.date != stored_date || trade.security_id != stored_security_id || sold_qty > stored_qty.to_d.abs
    end

    # [date, units on the sale date] for the day that leaves the least room,
    # from the sale date on: the most the sale could have removed and still
    # left that day at zero. Each day's room is converted to units on the sale
    # date before comparing, since a split changes the unit.
    def limiting_day
      @limiting_day ||= positions_with_sale
        .map { |date, room| [ date, Security::Split.unscale(room, split_factor(entry.date, date)) ] }
        .min_by { |_, room| room }
        .then { |date, room| [ date, sold_qty + room ] }
    end

    # Whether the position with this sale stays at or above zero on every day.
    def fits?
      positions_with_sale.all? { |_, room| room >= 0 }
    end

    # [date, position with this sale, in units of that day] for each day from
    # the sale date on where the position can change. Walks the days the way
    # Holding::ForwardCalculator does, a split rounding the running position
    # on its ex-date, so the check refuses exactly the sales that would take
    # the holdings below zero. Days before the first holding count as zero.
    # Holdings stop at today; after it, the walk visits only the days of the
    # account's other future-dated trades and of splits, so a trade dated far
    # ahead does not mean a walk over every day in between.
    def positions_with_sale
      @positions_with_sale ||= begin
        today = Date.current
        days = if entry.date <= today
          entry.date.upto(today).to_a
        else
          [ today, entry.date ]
        end
        last_day = [ entry.date, today, future_changes.keys.max ].compact.max
        days |= (future_changes.keys + split_ratios.keys).select { |day| day > today && day <= last_day }
        days.sort!

        base = position = nil
        days.filter_map do |day|
          ratio = split_ratios[day] if base
          scaled_base = base && (ratio ? Security::Split.scale(base, ratio) : base)
          change = if day <= today
            quantities.fetch(day, 0) - (scaled_base || 0)
          else
            future_changes.fetch(day, 0)
          end

          base = (scaled_base || 0) + change
          position = (position && ratio ? Security::Split.scale(position, ratio) : (position || 0)) + change
          position -= sold_qty if day == entry.date

          [ day, position ] if day >= entry.date
        end
      end
    end

    # Product of the split ratios after `from` up to and including `to`.
    def split_factor(from, to)
      split_ratios.select { |day, _| day > from && day <= to }.values.reduce(Rational(1), :*)
    end

    # Net units of this security that other trades dated after today add or remove, by day.
    def future_changes
      @future_changes ||= begin
        scope = account.entries.where(entryable_type: "Trade").where(date: Date.current.next_day..)
        scope = scope.where.not(id: entry.id) if entry.persisted?
        Trade.where(id: scope.select(:entryable_id), security_id: security.id)
          .joins(:entry).group("entries.date").sum(:qty)
          .transform_values(&:to_d)
      end
    end

    def split_ratios
      @split_ratios ||= security.splits.to_h { |split| [ split.ex_date, split.ratio ] }
    end

    def quantities
      @quantities ||= Holding::ForwardCalculator
        .new(account, security_ids: [ security.id ], excluded_entry_ids: entry.persisted? ? [ entry.id ] : nil)
        .calculate
        .select { |holding| holding.security_id == security.id }
        .to_h { |holding| [ holding.date, holding.qty.to_d ] }
    end

    def error_message
      limit_date, = limiting_day
      key = limit_date <= entry.date ? "exceeds_holding" : "exceeds_later_holding"

      I18n.t(
        "trades.sale_limit.#{key}",
        qty: format_qty(sold_qty),
        available: format_qty(available_qty),
        ticker: security.ticker,
        date: I18n.l(limit_date, format: :long)
      )
    end

    def format_qty(value)
      ActiveSupport::NumberHelper.number_to_rounded(value.to_d, precision: 18, strip_insignificant_zeros: true)
    end
end
