# Automatic Property Valuations

Sure can look up a property's estimated market value when you add it, and refresh that value automatically so it shows up in the account balance and net worth.

| Provider | Coverage | Lookup by | Free tier | Environment variable |
| --- | --- | --- | --- | --- |
| [RentCast](https://www.rentcast.io/api) | United States | Address | 50 requests/month | `RENTCAST_API_KEY` |
| [Realie](https://www.realie.ai/) | United States | Address | 25 requests/month | `REALIE_API_KEY` |
| [Chimnie](https://www.chimnie.com/) | United Kingdom (residential) | UPRN | Free valuations by UPRN (1 request/second) | `CHIMNIE_API_KEY` |

Each self-hosted instance needs its own API keys. Enter them under **Settings → Self-Hosting → Property valuation providers**, or set the environment variables on the web and worker services. A key set in the environment overrides the one saved in Settings.

Once a key is configured, **Add via &lt;provider&gt;** appears when you add a property.

## UK properties (Chimnie)

Chimnie values UK residential properties by their **UPRN** (Unique Property Reference Number), an identifier of up to 12 digits that every UK address has. Look a property up for free at [findmyaddress.co.uk](https://www.findmyaddress.co.uk) or ask your local council.

1. Create a free account at [dashboard.chimnie.com](https://dashboard.chimnie.com) and copy your API key. Sign-up requires a business or custom-domain email address; Gmail, Outlook and similar addresses are not accepted.
2. Paste it into **Settings → Self-Hosting → Chimnie**, or set `CHIMNIE_API_KEY`.
3. Add a property, choose **Add via Chimnie**, and enter the address, postcode and UPRN.
4. Review the estimate, its range and Chimnie's confidence, then confirm.

Sure only requests Chimnie's free valuation fields (estimated value, range and confidence). Valuations are stored in GBP, so the account currency must stay GBP for automatic refreshes to apply.

Chimnie only covers residential properties. Commercial or mixed-use UPRNs, and properties without an estimate, are reported as errors and no property is created.

## Refreshes

`SyncPropertyValuationsJob` runs on the 1st of each month. For each linked property it:

- skips the property if it was refreshed within the provider's minimum interval (one day for RentCast and Realie, one month for Chimnie)
- skips it when the address, UPRN or currency no longer fit the provider
- stops calling a provider for the rest of the run once that provider reports a rate limit
- records the new value as that day's balance valuation, named after the provider (e.g. "Chimnie valuation"). Refreshing twice on the same day updates that valuation instead of adding a second one.

On a property's overview tab, **Refresh valuation** requests a new value straight away. It skips the minimum interval but still counts against the provider's monthly request cap.

Every provider has a monthly request cap enforced by Sure. Raise it with `RENTCAST_MAX_REQUESTS_PER_MONTH`, `REALIE_MAX_REQUESTS_PER_MONTH` or `CHIMNIE_MAX_REQUESTS_PER_MONTH`. Chimnie's cap defaults to 1,000 requests a month because its UPRN valuations are free.

Failed and skipped refreshes are recorded in the debug log under the `provider_sync_error` category.

## Attribution

Chimnie valuation data contains Ordnance Survey, Royal Mail and HM Land Registry data. Sure shows the required attribution on the property preview.
