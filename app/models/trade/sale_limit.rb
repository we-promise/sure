# Stops a sale from taking a position below zero.
#
# A sale on day D removes units from D onward, so it is allowed only if the
# position without it covers the sale on every day from D through today (a
# split after D scales both sides). That way a back-dated sale cannot push a
# later day below zero either. The position comes from the calculator the
# account sync uses, so splits count the way they do on the holdings tab.
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

  def initialize(entry)
    @entry = entry
  end

  # Adds an error to the entry and returns false when the sale is too large.
  def validate
    return true unless applies?
    return true if sold_qty <= available_qty

    entry.errors.add(:base, error_message)
    false
  end

  # The most this sale may remove, in units on the sale date. Never below zero.
  def available_qty
    @available_qty ||= [ limiting_day.last, 0 ].max
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

    def applies?
      return false unless trade.is_a?(Trade) && security.present? && account.present? && entry.date.present?
      return false unless trade.qty.to_d.negative?
      return false if security.cash?
      return false if account.linked?

      entry.new_record? || worsens_existing_sale?
    end

    # An edit that only makes an existing sale smaller cannot take the position
    # lower than it already was, so it is not checked. That keeps old data,
    # which may already be oversold, editable (notes, price, a smaller qty).
    def worsens_existing_sale?
      previous_qty = trade.qty_was.to_d
      return true unless previous_qty.negative?

      entry.date_changed? || trade.security_id_changed? || sold_qty > previous_qty.abs
    end

    # [date, units on the sale date] for the day that leaves the least room.
    # A later day's position is divided by the splits since the sale date, so
    # it is compared in the same units as the sale. Days before the first
    # holding count as zero.
    def limiting_day
      @limiting_day ||= begin
        from = [ entry.date, Date.current ].min
        factor = Rational(1)

        from.upto(Date.current).map do |date|
          factor *= split_ratios[date] if date > from && split_ratios.key?(date)
          [ date, quantities.fetch(date, 0) / factor ]
        end.min_by(&:last)
      end
    end

    def split_ratios
      @split_ratios ||= security.splits.where(ex_date: ..Date.current).to_h { |split| [ split.ex_date, split.ratio ] }
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
      ActiveSupport::NumberHelper.number_to_rounded(value.to_d, precision: 8, strip_insignificant_zeros: true)
    end
end
