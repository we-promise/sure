module SecuritiesHelper
  # The security's current price in `currency`, the currency the trade or
  # position beside it is carried in, with the quote in its listing currency
  # in brackets so it compares with the purchase price and value next to it.
  # Without a rate only the quote shows, never relabelled as `currency`.
  def current_price_with_quote(security, currency)
    quote = security.current_price
    return if quote.nil?

    converted = security.current_price_in(currency)
    return format_money(quote) if converted.nil? || converted.currency == quote.currency

    safe_join([ format_money(converted), " ", tag.span("(#{format_money(quote)})", class: "text-secondary") ])
  end
end
