# frozen_string_literal: true

# Fetches the API key's balances and stores them, valued in USD, on the
# connection's single account. One API key is one Revolut X (sub-)account,
# so a connection always has exactly one RevolutXAccount.
class RevolutXItem::Importer
  ACCOUNT_ID = "default"
  # Quotes tried when an asset has no USD pair, converted to USD via ExchangeRate.
  FALLBACK_QUOTES = %w[EUR GBP].freeze

  attr_reader :revolut_x_item, :revolut_x_provider

  def initialize(revolut_x_item, revolut_x_provider:)
    @revolut_x_item = revolut_x_item
    @revolut_x_provider = revolut_x_provider
  end

  def import
    balances = Array(revolut_x_provider.get_balances)
    currencies = revolut_x_provider.get_currencies
    # Kept for the history floor only; its totals are never holdings.
    sub_accounts = revolut_x_provider.get_sub_accounts.to_h.dig("data", "sub_accounts")
    tickers = revolut_x_provider.get_tickers.to_h.fetch("data", []).index_by { |ticker| ticker["symbol"] }

    # Saved first: fiat_currency? reads the currencies from it.
    revolut_x_item.update!(raw_payload: {
      "balances" => balances,
      "sub_accounts" => sub_accounts,
      "currencies" => currencies,
      "imported_at" => Time.current.iso8601
    })

    assets = balances.filter_map { |balance| parse_asset(balance, tickers) }
    total_usd = assets.sum { |asset| asset["amount_usd"].to_d }

    account = upsert_account(assets, total_usd)
    { success: true, account_id: account.id, assets_imported: assets.size, total_usd: total_usd }
  end

  private

    def parse_asset(balance, tickers)
      symbol = balance["currency"].to_s.upcase
      total = balance["total"].to_d
      return if symbol.blank? || total.zero?

      fiat = revolut_x_item.fiat_currency?(symbol)
      price_usd = fiat ? fiat_usd_rate(symbol) : crypto_usd_price(symbol, tickers)

      {
        "symbol" => symbol,
        "name" => revolut_x_item.raw_payload.dig("currencies", symbol, "name"),
        "kind" => fiat ? "fiat" : "crypto",
        "total" => total.to_s("F"),
        "available" => balance["available"],
        "reserved" => balance["reserved"],
        "staked" => balance["staked"],
        # nil when nothing prices it; the processor skips and reports it.
        "price_usd" => price_usd&.to_s("F"),
        "amount_usd" => price_usd ? (total * price_usd).round(2).to_s("F") : "0"
      }
    end

    def crypto_usd_price(symbol, tickers)
      usd = ticker_price(tickers["#{symbol}/USD"])
      return usd if usd

      FALLBACK_QUOTES.each do |quote|
        price = ticker_price(tickers["#{symbol}/#{quote}"])
        rate = fiat_usd_rate(quote) if price
        return price * rate if rate
      end

      nil
    end

    def ticker_price(ticker)
      return nil unless ticker.is_a?(Hash)

      price = ticker["mid"].presence || ticker["last_price"].presence
      price&.to_d&.positive? ? price.to_d : nil
    end

    def fiat_usd_rate(code)
      Money.new(1, code).exchange_to("USD").amount
    rescue Money::ConversionError, Money::Currency::UnknownCurrencyError
      nil
    end

    def upsert_account(assets, total_usd)
      revolut_x_item.revolut_x_accounts.find_or_initialize_by(account_id: ACCOUNT_ID).tap do |account|
        account.update!(
          name: revolut_x_item.name,
          account_type: "exchange",
          currency: "USD",
          current_balance: total_usd,
          raw_payload: { "assets" => assets, "fetched_at" => Time.current.iso8601 }
        )
      end
    end
end
