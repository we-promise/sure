# Finds a card's annual fee in its own transactions: the largest fee charge in
# the last ~13 months gives the amount and the date it renews. A refund of
# most of that charge soon after means the fee was waived (e.g. a downgrade).
class CreditCard::AnnualFeeDetector
  FEE_PATTERN = /\b(annual|renewal)\s+(membership\s+)?fee\b|\bmembership\s+fee\b/i
  REFUND_PATTERN = /refund|reversal|credit/i
  LOOKBACK = 400.days

  Result = Data.define(:amount, :date, :refunded)

  attr_reader :card, :as_of

  def initialize(card, as_of: Date.current)
    @card = card
    @as_of = as_of
  end

  def detect
    charge = fee_entries.select { |e| e.amount.positive? && !e.name.match?(REFUND_PATTERN) }.max_by { |e| [ e.amount, e.date ] }
    return nil unless charge

    refunded = fee_entries.any? do |e|
      e.amount.negative? && e.date.between?(charge.date, charge.date + 90) && e.amount.abs >= charge.amount * 0.5
    end
    Result.new(amount: charge.amount, date: charge.date, refunded: refunded)
  end

  # Fills in whatever the card doesn't have yet. Returns the detection, or nil.
  def apply!
    result = detect
    return nil unless result

    card.annual_fee = result.amount if card.annual_fee.blank? && !result.refunded
    if card.annual_fee_month.blank? || card.annual_fee_day.blank?
      card.annual_fee_month = result.date.month
      card.annual_fee_day = result.date.day
    end
    card.save! if card.changed?
    result
  end

  private
    def fee_entries
      @fee_entries ||= card.account.entries
        .where(entryable_type: "Transaction", date: (as_of - LOOKBACK)..as_of)
        .where("entries.name ILIKE ?", "%fee%")
        .to_a
        .select { |e| e.name.to_s.match?(FEE_PATTERN) }
    end
end
