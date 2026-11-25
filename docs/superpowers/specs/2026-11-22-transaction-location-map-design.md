# Transaction Location Map — Design

## Purpose

A personal travel/spending log: let a transaction optionally carry a place
(name + coordinates), and view all located transactions as pins on a map.
Primary use case is reliving trips — "where did I go and spend money" — not
aggregate spending-by-region analytics.

No existing GitHub issue, PR, or Discussion in `we-promise/sure` proposes or
implements this (checked via issue/PR/discussion search across "map",
"location", "geo", "merchant location", "heatmap", "spending by city" —
all hits were false positives: exchange-code mapping, storage locations for
valuable items, redirect-handling bugs, etc.). This is a from-scratch
feature for this fork.

No provider integration in this family's accounts supplies location data
today: Cash Fineco is populated by a personal sync script (not Plaid), Cash
TR comes from the native Trade Republic integration (no location field in
its timeline events). Plaid's API does return a `location` object per
transaction, but Sure's `Plaid::Transaction::Processor` (`plaid_extra`)
does not currently store it — out of scope for this feature; locations are
manually entered.

## Scope

- Any transaction can optionally have a location — no restriction by
  category, account, or a "trip" grouping concept. Opt-in per transaction.
- A new top-level "Map" page shows every located transaction as a pin,
  clustered by proximity, filterable by date range and account (same query-
  param-driven filtering pattern used elsewhere in the app).
- Out of scope: pulling location from Plaid/other providers automatically,
  a "Trip" entity, spending-by-region aggregate analytics/heatmaps.

## Data Model

New nullable columns on `entries` (not a separate `locations` table — the
"opt-in per transaction" scope doesn't need normalization/reuse of places
at this volume):

- `location_lat` (decimal)
- `location_lng` (decimal)
- `location_name` (string)

Validations on `Entry`:
- Lat/lng must be present as a pair or both absent — no half-set location.
- Range checks: lat in -90..90, lng in -180..180.

Add `scope :located, -> { where.not(location_lat: nil) }` and a `located?`
instance method.

## Geocoding

New `Geocoding::NominatimClient` (PORO, `app/models/geocoding/`). Wraps
OpenStreetMap Nominatim:
- `search(query)` → forward geocoding, used by the autocomplete picker.
- `reverse(lat, lng)` → reverse geocoding, used when the user drags the
  confirm-map pin.

Free, no API key, no billing account — avoids introducing a new paid
dependency. Server-side only: Nominatim's usage policy requires a stable
identifying `User-Agent` and ~1 req/sec rate limiting, which is easier to
enforce centrally than to trust every browser client. Results cached via
`Rails.cache` keyed on the query string (place names recur across
transactions).

## Controllers / Endpoints

- `LocationSearchesController#index` — thin proxy: `q` param in, JSON
  suggestions out (via `NominatimClient#search`). Used only by the
  autocomplete picker's Stimulus controller.
- `MapsController#index` — new top-level page. Loads the current family's
  `located` entries, filtered by `date_range`/`account_id` query params
  (consistent with existing filter conventions), serializes to minimal JSON
  (id, lat, lng, name, amount, date, category) for the map.
- Setting a location reuses the **existing** `TransactionsController#update`
  — three new permitted params (`location_lat`, `location_lng`,
  `location_name`). No new write endpoint.

## Frontend

### Location picker (on the transaction edit form/drawer)

New `LocationPickerComponent` (`app/components/DS/` convention), collapsed
by default.

1. Search input (Stimulus controller, ~300ms debounce) hits
   `LocationSearchesController#index`, renders suggestions.
2. Picking a suggestion opens a small Leaflet preview map with a draggable
   marker (the "search first, map to confirm/adjust" flow, chosen over a
   search-only or map-only picker during brainstorming). Dragging
   re-reverse-geocodes the name.
3. Hidden fields (`location_lat`, `location_lng`, `location_name`) submit
   with the rest of the transaction form — no separate AJAX save step.
4. A "✕ remove location" control clears all three fields.

### Map page

- `MapsController#index` → Stimulus `map_controller.js`, mirroring the
  existing pattern of wrapping a JS visualization lib in a Stimulus
  controller (see `sankey_chart_controller.js` for D3). Initializes Leaflet
  + Leaflet.markercluster from the JSON payload.
- Pin/cluster click → popup with transaction name, amount, date, category
  chip, and a link to that transaction.
- Filters: plain `<select>`/date inputs resubmitting via query params — no
  new client-side filter framework.
- Empty state (no located transactions yet): explanatory message + a hint
  pointing at the transaction edit form, since the feature is opt-in and
  the map starts empty.

### Dependencies

Leaflet + Leaflet.markercluster (free, no API key, OSM tiles) — no new paid
dependency, consistent with the Nominatim choice.

## Error Handling

- Nominatim down/timeout → picker shows "Search unavailable, try again"
  inline. Never blocks saving the transaction — location is always optional.
- Nominatim returns zero results → "No matches, try a different search."
- Map page with zero located transactions → empty state, not a blank/broken
  map.

## Testing

- Minitest: `Entry` model validations (lat/lng pairing, range checks).
- `Geocoding::NominatimClient` — VCR-cassette the HTTP calls (per the
  project's testing guide).
- `LocationSearchesController` / `MapsController` request tests — auth
  boundary and family-scoping (must never leak another family's located
  transactions).
- One system test covering the picker flow end-to-end (search → pick →
  drag → save → reload shows the saved location), using a stubbed Nominatim
  response. No system test asserts on Leaflet's rendered map tiles/pixels
  (flake-risk not worth it).

## Open Questions

None outstanding — all decisions above were confirmed during brainstorming.
