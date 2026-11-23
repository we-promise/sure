# Checks an order read from an email for numbers and dates that don't add up. Problems are
# recorded for review; the purchase is still kept.
class Purchase::Validator
  TOLERANCE = BigDecimal("0.01")

  # Rebuilds an extraction from the raw output stored in a purchase's ai_metadata.
  def self.extraction_from(raw)
    decimal = ->(value) { value.present? ? BigDecimal(value.to_s) : nil }
    Provider::LlmConcept::PurchaseExtraction.new(
      is_order: raw["is_order"], not_order_reason: raw["not_order_reason"], merchant: raw["merchant"],
      order_number: raw["order_number"], order_date: (Date.iso8601(raw["order_date"].to_s) rescue nil),
      currency: raw["currency"], total: (decimal.(raw["total"]) rescue nil),
      shipping_cost: (decimal.(raw["shipping_cost"]) rescue nil), discount_total: (decimal.(raw["discount_total"]) rescue nil),
      payment_method: raw["payment_method"], items: Array(raw["items"]), confidence: raw["confidence"] || {}, notes: raw["notes"],
      receipt_files: Array(raw["receipt_files"])
    )
  end

  def initialize(extraction, family:)
    @extraction = extraction
    @family = family
  end

  # @return [Array<Hash>] each with a "reason" and optional details
  def problems
    [ total_problem, date_problem, currency_problem, items_problem, categories_problem ].compact
  end

  private
    attr_reader :extraction, :family

    def total_problem
      if extraction.total.nil?
        { "reason" => "missing_total" }
      elsif !extraction.total.positive?
        { "reason" => "non_positive_total" }
      end
    end

    def date_problem
      date = extraction.order_date
      if date.nil?
        { "reason" => "missing_date" }
      elsif date > Date.current
        { "reason" => "future_date", "date" => date.iso8601 }
      elsif date < Date.current - 1.year
        { "reason" => "too_old", "date" => date.iso8601 }
      end
    end

    def currency_problem
      { "reason" => "unknown_currency", "currency" => extraction.currency } unless known_currency?(extraction.currency)
    end

    # Items plus delivery, less order-level discounts, should give the total. Shops often show a
    # saving (free delivery in a bundle, a coupon) that the item prices already include, and the
    # model may still report it as a discount, so the total may also match without subtracting it.
    def items_problem
      return if extraction.total.nil? || items.empty?

      items_sum = items.sum { decimal(_1["amount"]) }
      shipping = decimal(extraction.shipping_cost)
      discount = decimal(extraction.discount_total)
      expected = items_sum + shipping - discount
      return if [ expected, items_sum + shipping ].any? { (_1 - extraction.total).abs <= TOLERANCE }

      {
        "reason" => "items_mismatch", "expected" => expected.to_s("F"), "actual" => extraction.total.to_s("F"),
        "items" => items_sum.to_s("F"), "shipping" => shipping.to_s("F"), "discount" => discount.to_s("F")
      }
    end

    def categories_problem
      known = family.categories.pluck(:name).map(&:downcase)
      unknown = items.filter_map { _1["category_name"].presence }.reject { known.include?(_1.downcase) }.uniq
      { "reason" => "unknown_categories", "names" => unknown } if unknown.any?
    end

    def items
      Array(extraction.items)
    end

    def known_currency?(code)
      code.present? && Money::Currency.new(code).present?
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
