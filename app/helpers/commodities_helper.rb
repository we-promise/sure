module CommoditiesHelper
  # Weight in the user's chosen unit (grams or troy ounces).
  def commodity_weight(grams, unit: Current.user.commodity_weight_unit)
    Commodity::Weight.format(grams, unit)
  end

  # Money, or a dash when the value is unknown (missing price or rate).
  def commodity_money(money, **options)
    money ? format_money(money, **options) : t("commodities.unknown")
  end

  # A gain/loss amount, coloured like a trend.
  def commodity_signed_money(money)
    return t("commodities.unknown") unless money

    tag.span(format_money(money), style: "color: #{Trend.new(current: money.amount, previous: 0).color}")
  end

  def commodity_trend(trend)
    return t("commodities.unknown") unless trend

    tag.span(style: "color: #{trend.color}") do
      safe_join([ format_money(trend.value), " (", trend.percent_formatted, ")" ])
    end
  end

  def commodity_currency_options
    Money::Currency.as_options.map { |currency| [ "#{currency.name} (#{currency.iso_code})", currency.iso_code ] }
  end

  def commodity_form_options
    Commodity::Item::FORMS.map { |form| [ t("commodities.forms.#{form}"), form ] }
  end
end
