# Arithmetic and sanity checks on what the model read from a receipt. Vision models fail by
# returning a believable wrong number rather than nothing, so every receipt that fails one of
# these is created but flagged for the user to review.
class ReceiptScan::Validator
  NIP_WEIGHTS = [ 6, 5, 7, 2, 3, 4, 5, 6, 7 ].freeze
  TOLERANCE = BigDecimal("0.01")
  MAX_AGE = 2.years

  def self.valid_nip?(nip)
    digits = nip.to_s.gsub(/[\s-]/, "")
    return false unless digits.match?(/\A\d{10}\z/)

    numbers = digits.chars.map(&:to_i)
    checksum = NIP_WEIGHTS.each_with_index.sum { |weight, index| weight * numbers[index] } % 11
    checksum != 10 && checksum == numbers.last
  end

  def initialize(extraction, account:, today: Date.current)
    @extraction = extraction
    @account = account
    @today = today
  end

  def problems
    [
      *total_problems,
      *date_problems,
      *nip_problems,
      *items_problems,
      *vat_problems,
      *currency_problems
    ]
  end

  private
    attr_reader :extraction, :account, :today

    def total
      extraction.total
    end

    def total_problems
      return [ problem(:missing_total) ] if total.nil?
      return [ problem(:non_positive_total, total: total.to_s) ] unless total.positive?

      []
    end

    def date_problems
      date = extraction.date
      return [ problem(:missing_date) ] if date.nil?
      return [ problem(:future_date, date: date.iso8601) ] if date > today
      return [ problem(:old_date, date: date.iso8601) ] if date < today - MAX_AGE

      []
    end

    def nip_problems
      return [] if extraction.nip.blank? || self.class.valid_nip?(extraction.nip)

      [ problem(:invalid_nip, nip: extraction.nip) ]
    end

    def items_problems
      return [] if total.nil? || extraction.line_items.blank?

      items_total = extraction.line_items.sum { |item| decimal(item["amount"]) - decimal(item["discount"]) }
      return [] if (items_total - total).abs <= TOLERANCE

      [ problem(:items_total_mismatch, items_total: items_total.to_s, total: total.to_s) ]
    end

    def vat_problems
      return [] if total.nil? || extraction.vat_breakdown.blank?

      gross_total = extraction.vat_breakdown.sum { |row| decimal(row["gross"]) }
      return [] if (gross_total - total).abs <= TOLERANCE

      [ problem(:vat_total_mismatch, vat_gross_total: gross_total.to_s, total: total.to_s) ]
    end

    def currency_problems
      code = extraction.currency
      return [ problem(:unknown_currency, currency: code) ] unless known_currency?(code)
      return [ problem(:currency_mismatch, currency: code, account_currency: account.currency) ] if code != account.currency

      []
    end

    def known_currency?(code)
      return false if code.blank?

      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def problem(reason, **details)
      { "reason" => reason.to_s, **details.stringify_keys }
    end
end
