# Spot price lookup used to prefill the purchase price in the item form.
class CommodityPricesController < ApplicationController
  def lookup
    metal = Commodity.metal(params[:code])
    date = Date.parse(params[:date].to_s)
    currency = Money::Currency.new(params[:currency].presence || Current.family.currency).iso_code
    return head(:not_found) unless metal

    unless Commodity::Price.latest_on(metal.code, date)
      Commodity::Price.import_provider_prices(start_date: date, codes: [ metal.code ])
    end

    row = Commodity::Price.latest_on(metal.code, date)
    price = Commodity::Price.per_troy_ounce(metal.code, date: date, currency: currency)

    render json: {
      price_per_ozt: price&.amount&.round(4),
      price_per_g: price && (price.amount / Commodity::Weight::GRAMS_PER_TROY_OUNCE).round(4),
      currency: currency,
      source: row&.source
    }
  rescue Date::Error, Money::Currency::UnknownCurrencyError
    head :unprocessable_entity
  end
end
