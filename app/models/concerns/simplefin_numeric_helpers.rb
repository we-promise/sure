# frozen_string_literal: true

module SimplefinNumericHelpers
  extend ActiveSupport::Concern

  private

    def to_decimal(value)
      return BigDecimal("0") if value.nil?
      case value
      when BigDecimal then value
      when String then BigDecimal(value) rescue BigDecimal("0")
      when Numeric then BigDecimal(value.to_s)
      else
        BigDecimal("0")
      end
    end

    def same_sign?(a, b)
      (a.positive? && b.positive?) || (a.negative? && b.negative?)
    end
end
