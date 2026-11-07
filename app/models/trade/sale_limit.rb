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
  # moment cannot both count the same units as available.
  def self.save(entry)
    entry.account.transaction do
      entry.account.lock!
      new(entry).validate && entry.save
    end
  end

  # Same as save, but raises ActiveRecord::RecordInvalid, for callers that
  # update several entries in one transaction (bulk edit). Any trade takes the
  # lock, a purchase too: moving a purchase later while a sale is checked
  # would let the sale count units that are no longer there on its date.
  # Bulk edits of ordinary transactions stay lock-free.
  def self.save!(entry)
    entry.account.transaction do
      limit = new(entry)
      entry.account.lock! if limit.guards_account?
      raise ActiveRecord::RecordInvalid, entry unless limit.validate
      entry.save!
    end
  end

  def initialize(entry)
    @entry = entry
  end

  # Adds an error to the entry and returns false when the sale is too large.
  def validate
    return true unless checks?
    return true if sold_qty <= available_qty

    entry.errors.add(:base, error_message)
    false
  end

  # The most this sale may remove, in units on the sale date. Never below zero.
  def available_qty
    @available_qty ||= [ limiting_day.last, 0 ].max
  end

  # Whether saving this entry can change what a sale on the same account may
  # remove, so it has to be serialized with sales being checked.
  def guards_account?
    trade.is_a?(Trade) && account.present? && !account.linked?
  end

  # Whether this entry is a sale (or worsens one) that the limit applies to.
  def checks?
    return false unless trade.is_a?(Trade) && security.present? && account.present? && entry.date.present?
    return false unless trade.qty.to_d.negative?
    return false if security.cash?
    return false if account.linked?

    entry.new_record? || worsens_existing_sale?
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

    # An edit that only makes an existing sale smaller cannot take the position
    # lower than it already was, so it is not checked. That keeps old data,
    # which may already be oversold, editable (notes, price, a smaller qty).
    def worsens_existing_sale?
      previous_qty = trade.qty_was.to_d
      return true unless previous_qty.negative?

      entry.date_changed? || trade.security_id_changed? || sold_qty > previous_qty.abs
    end

    # [date, units on the sale date] for the day that leaves the least room,
    # from the sale date on. Every quantity is converted into units of the
    # sale date, so a split in between scales it the way the holdings do.
    # Days before the first holding count as zero. Holdings stop at today, so
    # days after it add the account's other future-dated trades to today's
    # position: two sales dated tomorrow cannot both count the same units.
    def limiting_day
      @limiting_day ||= begin
        last_day = [ entry.date, Date.current, future_changes.keys.max ].compact.max
        entry.date.upto(last_day).map { |date| [ date, quantity_on(date) ] }.min_by(&:last)
      end
    end

    # The position on a day, in units of the sale date. After today, each
    # future-dated trade is converted on its own date, since a split announced
    # for a later day changes the units that trade is written in.
    def quantity_on(date)
      today = Date.current
      return in_sale_units(quantities.fetch(date, 0), date) if date <= today

      in_sale_units(quantities.fetch(today, 0), today) +
        future_changes.sum { |day, qty| day <= date ? in_sale_units(qty, day) : 0 }
    end

    # A quantity written in units of `date`, expressed in units of the sale date.
    def in_sale_units(qty, date)
      from, to = [ entry.date, date ].minmax
      factor = split_ratios.select { |day, _| day > from && day <= to }.values.reduce(Rational(1), :*)
      date >= entry.date ? qty / factor : qty * factor
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
