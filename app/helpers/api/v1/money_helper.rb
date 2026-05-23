# frozen_string_literal: true

module Api::V1::MoneyHelper
  def money_to_minor_units(money)
    (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
  end
end
