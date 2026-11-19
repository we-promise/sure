# Finds a card's annual fee in its own transactions. A fee charge refunded
# for most of its amount soon after was waived (e.g. a downgrade). The
# largest charge in the last ~13 months that wasn't waived gives the amount
# and the date it renews, the most recent one on a tie. If every charge was
# waived, the largest waived one still gives the renewal date.
# Only posted entries in the card's own currency count, so the amount stored
# on the card is always in that currency.
class CreditCard::AnnualFeeDetector
  FEE_PATTERN = /\b(annual|renewal)\s+(membership\s+)?fee\b|\bmembership\s+fee\b/i
  # Credits for these fees never offset an annual fee ("Late Fee Refund").
  OTHER_FEE_PATTERN = /\b(late|interest|foreign|transaction|balance\s+transfer|cash\s+advance|returned|over-?limit|atm)\b/i
  LOOKBACK = 400.days
  REFUND_WINDOW = 90

  Result = Data.define(:amount, :date, :refunded)

  attr_reader :card, :as_of

  def initialize(card, as_of: Date.current)
    @card = card
    @as_of = as_of
  end

  def detect
    charges = fee_charges
    return nil if charges.empty?

    waived, kept = charges.partition { |charge| refunded?(charge) }
    charge = (kept.presence || waived).max_by { |e| [ e.amount, e.date ] }
    Result.new(amount: charge.amount, date: charge.date, refunded: kept.empty?)
  end

  # Fills in whatever the card doesn't have yet. Returns the detection, or nil.
  def apply!
    result = detect
    return nil unless result

    # The lock reloads the card, so a value saved since it was loaded is
    # kept. Each field, and each part of the date, is filled in only when
    # it's still missing.
    card.with_lock do
      card.annual_fee = result.amount if card.annual_fee.blank? && !result.refunded
      card.annual_fee_month = result.date.month if card.annual_fee_month.blank?
      card.annual_fee_day = result.date.day if card.annual_fee_day.blank?
      card.save! if card.changed?
    end
    result
  end

  private
    def fee_named_entries
      @fee_named_entries ||= card.account.entries
        .excluding_pending
        .where(entryable_type: "Transaction", currency: card.account.currency, date: (as_of - LOOKBACK)..as_of)
        .where("entries.name ILIKE ?", "%fee%")
        .to_a
    end

    def fee_charges
      fee_named_entries.select { |e| e.amount.positive? && e.name.to_s.match?(FEE_PATTERN) }
    end

    # A refund need not repeat the fee's wording ("Fee Refund", "Annual fee
    # credit"), so any fee-named credit soon after the charge counts, unless
    # it names a different kind of fee.
    def fee_credits
      fee_named_entries.select { |e| e.amount.negative? && !e.name.to_s.match?(OTHER_FEE_PATTERN) }
    end

    def refunded?(charge)
      fee_credits.any? do |e|
        e.date.between?(charge.date, charge.date + REFUND_WINDOW) && e.amount.abs >= charge.amount * 0.5
      end
    end
end
