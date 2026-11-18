# Automatic Property Valuations

Sure can look up a property's estimated market value when you add it, and refresh that value automatically so it shows up in the account balance and net worth.

| Provider | Coverage | Lookup by | Free tier | Environment variable |
| --- | --- | --- | --- | --- |
| [RentCast](https://www.rentcast.io/api) | United States | Address | 50 requests/month | `RENTCAST_API_KEY` |
| [Realie](https://www.realie.ai/) | United States | Address | 25 requests/month | `REALIE_API_KEY` |
| [Chimnie](https://www.chimnie.com/) | United Kingdom (residential) | UPRN | Free valuations by UPRN (1 request/second) | `CHIMNIE_API_KEY` |
| [DVF](https://www.data.gouv.fr/fr/datasets/demandes-de-valeurs-foncieres-geolocalisees/) | France (apartments and houses, except Alsace-Moselle and Mayotte) | Address, type and living area | Free open data, no key | `DVF_ENABLED=true` |

Each self-hosted instance needs its own API keys. Enter them under **Settings → Self-Hosting → Property valuation providers**, or set the environment variables on the web and worker services. A key set in the environment overrides the one saved in Settings.

Once a key is configured, **Add via &lt;provider&gt;** appears when you add a property. DVF needs no key: turn it on under **Settings → Self-Hosting → DVF (France)** instead.

## UK properties (Chimnie)

Chimnie values UK residential properties by their **UPRN** (Unique Property Reference Number), an identifier of up to 12 digits that every UK address has. Look a property up for free at [findmyaddress.co.uk](https://www.findmyaddress.co.uk) or ask your local council.

1. Create a free account at [dashboard.chimnie.com](https://dashboard.chimnie.com) and copy your API key. Sign-up requires a business or custom-domain email address; Gmail, Outlook and similar addresses are not accepted.
2. Paste it into **Settings → Self-Hosting → Chimnie**, or set `CHIMNIE_API_KEY`.
3. Add a property, choose **Add via Chimnie**, and enter the address, postcode and UPRN.
4. Review the estimate, its range and Chimnie's confidence, then confirm.

Sure only requests Chimnie's free valuation fields (estimated value, range and confidence). Valuations are stored in GBP, so the account currency must stay GBP for automatic refreshes to apply.

Chimnie only covers residential properties. Commercial or mixed-use UPRNs, and properties without an estimate, are reported as errors and no property is created.

## French properties (DVF)

DVF (*Demandes de valeurs foncières*) is the French tax administration's record of every property sale, published as open data and republished with coordinates by Etalab under the Licence Ouverte 2.0. Sure estimates a property from comparable sales around it, with no API key and no account:

1. Turn on **Settings → Self-Hosting → DVF (France)**, or set `DVF_ENABLED=true`. This lets Sure call the Géoplateforme geocoder (`data.geopf.fr`) and download sales files from `files.data.gouv.fr`.
2. Add a property, choose **Add via DVF**, and enter the address, postcode, property type (apartment or house) and living area.
3. Review the estimate, its range and confidence, then confirm.

An existing property can be linked too, from its overview tab, once its address is in France, its account is in EUR, and it has a living area and an apartment or house type.

How the estimate is made:

- comparables are single-property sales of the same type (apartment or house) within 500 m over the last 12 months of published data, with a living area within ±40% of the property's; the Carrez area is used when the deed gives a plausible one
- if there are fewer than 15, the search widens to 24 months, then to 1 km; the tier reached sets the confidence (high, medium, low)
- each sale's price per m² is brought to the latest price level with a quarterly median index, since DVF is published six to twelve months late
- the value is the median price per m² times the living area, and the range is the 25th to 75th percentile

DVF doesn't record a property's floor, condition or view, so the estimate can differ from a professional appraisal by several percent. There is no data for Alsace-Moselle (Moselle, Bas-Rhin, Haut-Rhin), which keeps its own land register, or for Mayotte.

`DVF_RADIUS_METERS` changes the 500 m starting radius, and `DVF_URL` and `DVF_GEOCODER_URL` point Sure at mirrors of the open data services.

## Refreshes

`SyncPropertyValuationsJob` runs on the 1st of each month. For each linked property it:

- skips the property if it was refreshed within the provider's minimum interval (one day for RentCast and Realie, one month for Chimnie and DVF)
- skips it when the address, UPRN, living area, property type or currency no longer fit the provider
- stops calling a provider for the rest of the run once that provider reports a rate limit
- records the new value as that day's balance valuation, named after the provider (e.g. "Chimnie valuation"). Refreshing twice on the same day updates that valuation instead of adding a second one.

On a property's overview tab, **Refresh valuation** requests a new value straight away. It skips the minimum interval but still counts against the provider's monthly request cap.

Every provider has a monthly request cap enforced by Sure. Raise it with `RENTCAST_MAX_REQUESTS_PER_MONTH`, `REALIE_MAX_REQUESTS_PER_MONTH`, `CHIMNIE_MAX_REQUESTS_PER_MONTH` or `DVF_MAX_REQUESTS_PER_MONTH`. Chimnie's cap defaults to 1,000 requests a month because its UPRN valuations are free; DVF's defaults to 500 lookups, only as a guard against runaway refreshes.

Failed and skipped refreshes are recorded in the debug log under the `provider_sync_error` category.

## Attribution

Chimnie valuation data contains Ordnance Survey, Royal Mail and HM Land Registry data. DVF is published by the DGFiP and Etalab under the Licence Ouverte 2.0. Sure shows the attribution on the property preview.
