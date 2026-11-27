module SecuritiesHelper
  # The security's current price in `currency`, the currency the trade or
  # position beside it is carried in, with the quote in its listing currency
  # in brackets so it compares with the purchase price and value next to it.
  # Without a rate only the quote shows, never relabelled as `currency`.
  def current_price_with_quote(security, currency)
    quote = security.current_price
    return last_completed_price_with_date(security) unless quote

    converted = security.current_price_in(currency)
    return format_money(quote) if converted.nil? || converted.currency == quote.currency

    safe_join([ format_money(converted), " ", tag.span("(#{format_money(quote)})", class: "text-secondary") ])
  end

  private

    def last_completed_price_with_date(security)
      price = security.last_completed_scalable_price
      return unless price

      safe_join([
        format_money(Money.new(price.price, price.currency)),
        " ",
        tag.span(t("shared.last_close_as_of", date: l(price.date, format: :long)), class: "text-secondary")
      ])
    end
end
