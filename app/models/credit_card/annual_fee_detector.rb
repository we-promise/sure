# Finds a card's annual fee in its own transactions: the largest fee charge in
# the last ~13 months gives the amount and the date it renews. A refund of
# most of that charge soon after means the fee was waived (e.g. a downgrade).
# Only entries in the card's own currency count, so the amount stored on the
# card is always in that currency.
class CreditCard::AnnualFeeDetector
  FEE_PATTERN = /\b(annual|renewal)\s+(membership\s+)?fee\b|\bmembership\s+fee\b/i
  LOOKBACK = 400.days
  REFUND_WINDOW = 90

  Result = Data.define(:amount, :date, :refunded)

  attr_reader :card, :as_of

  def initialize(card, as_of: Date.current)
    @card = card
    @as_of = as_of
  end

  def detect
    charge = fee_charges.max_by { |e| [ e.amount, e.date ] }
    return nil unless charge

    # A refund need not repeat the fee's wording ("Fee Refund", "Annual fee
    # credit"), so any fee-named credit soon after the charge counts.
    refunded = fee_credits.any? do |e|
      e.date.between?(charge.date, charge.date + REFUND_WINDOW) && e.amount.abs >= charge.amount * 0.5
    end
    Result.new(amount: charge.amount, date: charge.date, refunded: refunded)
  end

  # Fills in whatever the card doesn't have yet. Returns the detection, or nil.
  def apply!
    result = detect
    return nil unless result

    card.annual_fee = result.amount if card.annual_fee.blank? && !result.refunded
    # Each part of the date is filled in only when it's missing, so a month
    # or day the user entered is kept.
    card.annual_fee_month = result.date.month if card.annual_fee_month.blank?
    card.annual_fee_day = result.date.day if card.annual_fee_day.blank?
    card.save! if card.changed?
    result
  end

  private
    def fee_named_entries
      @fee_named_entries ||= card.account.entries
        .where(entryable_type: "Transaction", currency: card.account.currency, date: (as_of - LOOKBACK)..as_of)
        .where("entries.name ILIKE ?", "%fee%")
        .to_a
    end

    def fee_charges
      fee_named_entries.select { |e| e.amount.positive? && e.name.to_s.match?(FEE_PATTERN) }
    end

    def fee_credits
      fee_named_entries.select { |e| e.amount.negative? }
    end
end
