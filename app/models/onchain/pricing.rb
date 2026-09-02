# frozen_string_literal: true

# Whether an on-chain asset can be valued in a family's currency, and why not.
#
# Two things have to be in place, and each is a separate setting the user has to
# have made. The only provider that prices bare crypto symbols quotes in USD, so
# a family whose currency is not USD needs one exchange rate on top — and Sure's
# default exchange rate provider requires an API key, so a self-hosted install
# with no key has no FX at all.
#
# Either gap ends the same way: quantities tracked, everything valued at zero,
# reported as a broken sync. So both are stated before linking rather than
# discovered afterwards.
class Onchain::Pricing
  PRICE_CURRENCY = "USD"

  class << self
    def ready_for?(currency)
      missing_for(currency).empty?
    end

    # @return [Array<Symbol>] :crypto_provider, :exchange_rate
    def missing_for(currency)
      reasons = []
      reasons << :crypto_provider unless Onchain::SecurityResolver.price_provider_enabled?
      reasons << :exchange_rate if fx_required?(currency) && !fx_configured?
      reasons
    end

    def fx_required?(currency)
      currency.to_s.upcase.presence && currency.to_s.upcase != PRICE_CURRENCY
    end

    def fx_configured?
      ExchangeRate.provider.present?
    rescue StandardError
      false
    end
  end
end
