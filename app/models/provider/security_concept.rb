module Provider::SecurityConcept
  extend ActiveSupport::Concern

  # NOTE: This `Security` is a lightweight Data value object used for search results.
  # Inside provider classes that `include SecurityConcept`, unqualified `Security`
  # resolves to this Data class — NOT to `::Security` (the ActiveRecord model).
  Security = Data.define(:symbol, :name, :logo_url, :exchange_operating_mic, :country_code, :currency) do
    def initialize(symbol:, name:, logo_url:, exchange_operating_mic:, country_code:, currency: nil)
      super
    end
  end
  # `sector` and `industry` are free text by design. Provider taxonomies
  # disagree -- EODHD's `General.Sector` is not GICS, and no two agree on
  # wording -- so a constraint here would reject a value a provider
  # legitimately returns and break ingestion for that provider.
  #
  # Defaulted in an `initialize` override, the same way the `Security` above
  # defaults `currency:`. This Data has ten implementers; without the
  # defaults every one of them would raise at construction the day these
  # fields were added.
  SecurityInfo = Data.define(:symbol, :name, :links, :logo_url, :description, :kind, :exchange_operating_mic,
                             :sector, :industry) do
    def initialize(symbol:, name:, links:, logo_url:, description:, kind:, exchange_operating_mic:,
                   sector: nil, industry: nil)
      super
    end
  end
  Price = Data.define(:symbol, :date, :price, :currency, :exchange_operating_mic)

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    raise NotImplementedError, "Subclasses must implement #search_securities"
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_info"
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_price"
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_prices"
  end

  # Whether this provider can answer for a security's sector/industry.
  # DECLARED, not inferred from a response, because the caller has to decide
  # whether to ASK before it has one.
  #
  # `Security::Provided#import_provider_details` gates the fetch on evidence
  # that it has already asked -- a filled `sector`/`industry`, or a
  # `classification_fetched_at` stamp. Without a capability to consult, that
  # gate conflates "asked, nothing there" with "asked a provider that has
  # nothing to give", and the two need opposite handling: the first should
  # never be asked again, the second should be asked as soon as a capable
  # provider is configured.
  #
  # THE DEFAULT IS FALSE, and that is a trade rather than an obvious choice.
  # Seven of the ten security providers supply no classification, so false is
  # right for most of them and stops a per-sync fetch that answers nothing.
  # The cost: a provider added later that DOES supply one, and forgets to say
  # so, is silently never asked, and it reads as missing data rather than a
  # missing line here. A new provider that returns `sector:` or `industry:`
  # from `fetch_security_info` must override this.
  #
  # Same shape as `max_history_days` below: declared on the concept, safely
  # defaulted, overridden by the providers it applies to.
  def supplies_classification?
    false
  end

  # Maximum number of calendar days of historical data the provider can return.
  # Callers should clamp start_date to avoid requesting data beyond this window.
  # Override in subclasses with provider-specific limits.
  def max_history_days
    nil # nil means no known limit
  end
end
