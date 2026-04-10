# Adding a New Securities Price Provider

This guide covers every step needed to add a new securities price provider (like Tiingo, EODHD, etc.) to the application.

## Architecture Overview

```
User searches ticker in combobox
  → SecuritiesController#index
    → Security.search_provider (queries all enabled providers concurrently)
      → Provider::YourProvider#search_securities
        → Returns results with provider key attached
          → User selects one → price_provider stored on Security record

Account sync / price fetch
  → Security#price_data_provider (looks up provider by security.price_provider)
    → Provider::YourProvider#fetch_security_prices
      → Security::Price::Importer gap-fills and upserts into DB
```

Key files:
- Provider class: `app/models/provider/your_provider.rb`
- Registry: `app/models/provider/registry.rb`
- Settings: `app/models/setting.rb`
- Provider resolution: `app/models/security/provided.rb`
- Price import: `app/models/security/price/importer.rb`
- Market data sync: `app/models/account/market_data_importer.rb`

## Step 1: Create the Provider Class

Create `app/models/provider/your_provider.rb`:

```ruby
class Provider::YourProvider < Provider
  include SecurityConcept

  # Include if your provider has rate limits
  include RateLimitable

  # Custom error classes
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Rate limiting (only if you included RateLimitable)
  MIN_REQUEST_INTERVAL = 1.0 # seconds between requests

  def initialize(api_key)
    @api_key = api_key
  end

  # --- Required Methods ---

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      response = client.get("#{base_url}/search", params: { q: symbol })
      parsed = JSON.parse(response.body)

      parsed.map do |result|
        SecurityConcept::Security.new(
          symbol:                 result["ticker"],
          name:                   result["name"],
          logo_url:               result["logo"],
          exchange_operating_mic: map_exchange_to_mic(result["exchange"]),
          country_code:           result["country"],
          currency:               result["currency"]
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      response = client.get("#{base_url}/info/#{symbol}")
      parsed = JSON.parse(response.body)

      SecurityConcept::SecurityInfo.new(
        symbol:                 parsed["ticker"],
        name:                   parsed["name"],
        links:                  parsed["website"],
        logo_url:               parsed["logo"],
        description:            parsed["description"],
        kind:                   parsed["type"],       # e.g. "common stock", "etf"
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    with_provider_response do
      response = client.get("#{base_url}/price/#{symbol}", params: { date: date.to_s })
      parsed = JSON.parse(response.body)

      SecurityConcept::Price.new(
        symbol:                 symbol,
        date:                   Date.parse(parsed["date"]),
        price:                  parsed["close"].to_f,
        currency:               parsed["currency"],
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      response = client.get("#{base_url}/prices/#{symbol}", params: {
        start: start_date.to_s,
        end: end_date.to_s
      })
      parsed = JSON.parse(response.body)

      parsed.map do |row|
        SecurityConcept::Price.new(
          symbol:                 symbol,
          date:                   Date.parse(row["date"]),
          price:                  row["close"].to_f,
          currency:               row["currency"],
          exchange_operating_mic: exchange_operating_mic
        )
      end
    end
  end

  # Optional: limit how far back the importer fetches history.
  # nil = unlimited. Free tiers often have limits.
  def max_history_days
    365
  end

  # Optional: health check for admin UI
  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/status")
      JSON.parse(response.body)["status"] == "ok"
    end
  end

  # Optional: usage stats for admin UI
  def usage
    with_provider_response do
      Provider::UsageData.new(
        used: daily_request_count,
        limit: MAX_REQUESTS_PER_DAY,
        utilization: (daily_request_count.to_f / MAX_REQUESTS_PER_DAY * 100).round(1),
        plan: "Free"
      )
    end
  end

  private

    def base_url
      "https://api.yourprovider.com/v1"
    end

    def client
      @client ||= Faraday.new do |conn|
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.response :raise_error
      end
    end

    # Map provider's exchange names to ISO 10383 MIC codes.
    # This is critical — the app uses MIC codes everywhere.
    def map_exchange_to_mic(exchange_name)
      {
        "NASDAQ" => "XNAS",
        "NYSE"   => "XNYS",
        "LSE"    => "XLON",
        "XETRA"  => "XETR",
        "AMS"    => "XAMS"
        # Add all exchanges your provider returns
      }[exchange_name]
    end
end
```

### Data Structures (defined in `SecurityConcept`)

All methods must return these exact types (wrapped in `with_provider_response`):

```ruby
SecurityConcept::Security    = Data.define(:symbol, :name, :logo_url, :exchange_operating_mic, :country_code, :currency)
SecurityConcept::SecurityInfo = Data.define(:symbol, :name, :links, :logo_url, :description, :kind, :exchange_operating_mic)
SecurityConcept::Price       = Data.define(:symbol, :date, :price, :currency, :exchange_operating_mic)
```

### Error Handling

All public methods must be wrapped in `with_provider_response`:

```ruby
def some_method
  with_provider_response do
    # Your logic. Raise on errors.
    # The block return value becomes response.data
  end
end
```

Callers always receive a `Provider::Response`:
```ruby
response = provider.fetch_security_price(...)
response.success?  # true/false
response.data      # the return value from the block
response.error     # Provider::Error instance (on failure)
```

### Rate Limiting

If your provider has rate limits, include `RateLimitable` and use cache-based atomic counters:

```ruby
include RateLimitable

MIN_REQUEST_INTERVAL = 1.5 # seconds between requests

MAX_REQUESTS_PER_DAY = 20

private

  def throttle_request
    super # enforces MIN_REQUEST_INTERVAL
    enforce_daily_limit!
  end

  def enforce_daily_limit!
    cache_key = "your_provider:daily:#{Date.current}"
    count = Rails.cache.increment(cache_key, 1, expires_in: 1.day, initial: 0)
    raise RateLimitError, "Daily limit reached" if count > MAX_REQUESTS_PER_DAY
  end
```

### Exchange Mapping

Every provider has its own naming for exchanges. You must map them to ISO 10383 MIC codes. Define bidirectional maps:

```ruby
# Provider exchange name → MIC code (for parsing search results)
PROVIDER_TO_MIC = { "NASDAQ" => "XNAS", ... }.freeze

# MIC code → Provider exchange name (for building API requests)
MIC_TO_PROVIDER = PROVIDER_TO_MIC.invert.freeze
```

See `config/exchanges.yml` for the full list of MIC codes and their display names.

### Currency Handling

Some providers don't return currency in every response. Common pattern: cache currency from search results and reuse later:

```ruby
def search_securities(symbol, **opts)
  with_provider_response do
    results = api_call(...)
    results.each do |r|
      Rails.cache.write("your_provider:currency:#{r[:ticker].upcase}", r[:currency], expires_in: 24.hours)
    end
    # ...
  end
end

def fetch_security_prices(symbol:, **)
  with_provider_response do
    # ...
    currency = Rails.cache.read("your_provider:currency:#{symbol.upcase}") || fallback_currency(exchange)
    # ...
  end
end
```

## Step 2: Register in the Provider Registry

Edit `app/models/provider/registry.rb`:

**Add to `available_providers`** (around line 144):

```ruby
def available_providers
  case concept
  when :exchange_rates
    %i[twelve_data yahoo_finance]
  when :securities
    %i[twelve_data yahoo_finance tiingo eodhd alpha_vantage mfapi your_provider]
  # ...
  end
end
```

**Add the factory method** (private section, around line 85):

```ruby
def your_provider
  api_key = ENV["YOUR_PROVIDER_API_KEY"].presence || Setting.your_provider_api_key
  return nil unless api_key.present?
  Provider::YourProvider.new(api_key)
end
```

If your provider needs no API key (like Yahoo Finance or MFAPI):

```ruby
def your_provider
  Provider::YourProvider.new
end
```

## Step 3: Add Settings

Edit `app/models/setting.rb`:

**Add the API key field** (around line 40):

```ruby
field :your_provider_api_key, type: :string, default: ENV["YOUR_PROVIDER_API_KEY"]
```

**Add to encrypted fields** (in `EncryptedSettingFields`, around line 55):

```ruby
ENCRYPTED_FIELDS = %i[
  twelve_data_api_key
  tiingo_api_key
  eodhd_api_key
  alpha_vantage_api_key
  your_provider_api_key    # ← add here
  openai_access_token
  external_assistant_token
]
```

## Step 4: Add to the Settings UI

### Hostings Controller

Edit `app/controllers/settings/hostings_controller.rb`:

**In `show`** — add a flag to control visibility:

```ruby
@show_your_provider_settings = enabled_securities.include?("your_provider")
```

**In `update`** — handle the API key:

```ruby
update_encrypted_setting(:your_provider_api_key)
```

### Hostings View

Edit the settings view to add your provider's checkbox and API key field. Follow the existing pattern for Tiingo/EODHD (checkbox in the provider selection list, API key input shown when enabled).

## Step 5: Add Translations

Edit `config/locales/views/settings/hostings/en.yml`:

**Add provider name** (under `provider_selection.providers`):

```yaml
providers:
  twelve_data: "Twelve Data"
  yahoo_finance: "Yahoo Finance"
  tiingo: "Tiingo"
  eodhd: "EODHD"
  alpha_vantage: "Alpha Vantage"
  mfapi: "MFAPI.in"
  your_provider: "Your Provider"    # ← add here
```

**Add hint text** (under `provider_selection`):

```yaml
your_provider_hint: "requires API key, N calls/day limit"
```

**Add settings section** (for the API key input):

```yaml
your_provider_settings:
  title: "Your Provider"
  description: "Get your API key from https://yourprovider.com/dashboard"
  label: "API Key"
  env_configured_message: "The YOUR_PROVIDER_API_KEY environment variable is set."
```

Also add a display name in `config/locales/en.yml` under `securities.providers`:

```yaml
securities:
  providers:
    your_provider: "Your Provider"
```

This is used in the combobox dropdown to show which provider each search result comes from.

## Step 6: Test

### Manual Testing

```ruby
# In rails console:
provider = Provider::YourProvider.new("your_api_key")

# Search
response = provider.search_securities("AAPL")
response.success? # => true
response.data     # => [SecurityConcept::Security(...), ...]

# Price
response = provider.fetch_security_price(symbol: "AAPL", exchange_operating_mic: "XNAS", date: Date.current)
response.data.price    # => 150.25
response.data.currency # => "USD"

# Historical prices
response = provider.fetch_security_prices(symbol: "AAPL", exchange_operating_mic: "XNAS", start_date: 30.days.ago.to_date, end_date: Date.current)
response.data.size # => ~30
```

### Enable and Search

```ruby
# Enable the provider
Setting.securities_providers = "your_provider"

# Search via the app's multi-provider system
results = Security.search_provider("AAPL")
results.map { |s| [s.ticker, s.price_provider] }
# => [["AAPL", "your_provider"]]

# Create a security with your provider
security = Security::Resolver.new("AAPL", exchange_operating_mic: "XNAS", price_provider: "your_provider").resolve
security.price_provider # => "your_provider"

# Import prices
security.import_provider_prices(start_date: 30.days.ago.to_date, end_date: Date.current)
security.prices.count
```

## How It All Connects

### Search Flow

When a user types in the securities combobox:

1. `SecuritiesController#index` calls `Security.search_provider(query)` (`app/models/security/provided.rb`)
2. `search_provider` queries **all enabled providers concurrently** using `Concurrent::Promises` with an 8-second timeout per provider
3. Results are deduplicated (key: `ticker|exchange|provider`) and ranked by relevance
4. Each result's `ComboboxOption#id` is `"TICKER|EXCHANGE|PROVIDER"` (e.g., `"AAPL|XNAS|your_provider"`)
5. When the user selects one, `price_provider` is stored on the Security record

### Price Fetch Flow

When prices are needed:

1. `Security#price_data_provider` looks up the provider by `security.price_provider`
2. If the assigned provider is unavailable (disabled in settings), returns `nil` — the security is skipped, not silently switched
3. If no provider assigned, falls back to the first enabled provider
4. `Security::Price::Importer` calls `fetch_security_prices` and gap-fills missing dates using LOCF (last observation carried forward)
5. Prices are upserted in batches of 200

### Provider Resolution Priority

```
security.price_provider present?
  ├── YES → Security.provider_for(price_provider)
  │         ├── Provider enabled & configured → use it
  │         └── Provider unavailable → return nil (skip security)
  └── NO  → Security.providers.first (first enabled provider)
```

## Checklist

- [ ] Provider class at `app/models/provider/your_provider.rb`
  - [ ] Inherits from `Provider`
  - [ ] Includes `SecurityConcept`
  - [ ] Implements `search_securities`, `fetch_security_info`, `fetch_security_price`, `fetch_security_prices`
  - [ ] Returns correct `Data.define` types
  - [ ] All methods wrapped in `with_provider_response`
  - [ ] Exchange names mapped to MIC codes
  - [ ] Currency handling (cached or mapped)
  - [ ] Rate limiting if applicable
- [ ] Registry entry in `app/models/provider/registry.rb`
  - [ ] Added to `available_providers` for `:securities`
  - [ ] Private factory method with ENV + Setting fallback
- [ ] Setting field in `app/models/setting.rb` (if API key needed)
  - [ ] `field :your_provider_api_key`
  - [ ] Added to `ENCRYPTED_FIELDS`
- [ ] Settings UI in hostings controller/view
- [ ] Translations in `config/locales/`
  - [ ] Provider name in `provider_selection.providers`
  - [ ] Provider name in `securities.providers` (for combobox display)
  - [ ] Hint text and settings section
- [ ] Tested: search, single price, historical prices, info
