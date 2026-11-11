# Estimates a French property's value from comparable sales in DVF
# (Demandes de valeurs foncières): the median price per m² of similar nearby
# sales, brought to the newest prices in the data, times the property's area.
#
# Pure logic with no I/O, so it can be tested on hand-built sales.
class Provider::Dvf::Estimator
  Sale = Data.define(:date, :price, :area, :latitude, :longitude) do
    def price_per_sqm
      price / area
    end
  end

  Estimate = Data.define(:valuation, :valuation_low, :valuation_high, :price_per_sqm, :sales_count, :radius, :months, :confidence)

  # Below this many comparables a search tier is too noisy, so the search
  # widens to the next tier.
  MIN_SALES = 15

  # Search tiers, narrowest first. A tier that reaches MIN_SALES sets the
  # confidence of the estimate.
  TIERS = [
    { radius_factor: 1, months: 12, confidence: "high" },
    { radius_factor: 1, months: 24, confidence: "medium" },
    { radius_factor: 2, months: 24, confidence: "low" }
  ].freeze

  # Comparables must be within this fraction of the property's area. Sure has
  # no room count, and on Paris data this band gives the same median as
  # filtering on ±1 room.
  AREA_BAND = 0.4

  # A Carrez area this far off the built area usually belongs to another lot.
  CARREZ_TOLERANCE = 0.4

  # Months of sales whose median sets the price level comparables are
  # brought to.
  LATEST_LEVEL_MONTHS = 6

  DEFAULT_RADIUS = 500

  EARTH_RADIUS = 6_371_000

  # CSV columns the estimate reads; rows are trimmed to these before caching.
  ROW_COLUMNS = (%w[
    id_mutation date_mutation nature_mutation valeur_fonciere type_local
    surface_reelle_bati nombre_pieces_principales id_parcelle numero_volume latitude longitude
  ] + (1..5).flat_map { |i| [ "lot#{i}_numero", "lot#{i}_surface_carrez" ] }).freeze

  # One sale per mutation, and only plain sales of a single property of
  # `local_type` ("Appartement" or "Maison"), optionally with outbuildings
  # ("Dépendance") or bare land rows. Mutations covering several units, or
  # mixing in a shop or another home, price several things at once.
  def self.sales_from_rows(rows, local_type:)
    rows.group_by { |row| row["id_mutation"] }.filter_map do |_id, group|
      next unless group.first["nature_mutation"] == "Vente"

      locals = group.select { |row| row["type_local"] == local_type }.uniq { |row| unit_key(row) }
      next unless locals.size == 1
      next if group.any? { |row| row["type_local"].present? && row["type_local"] != local_type && row["type_local"] != "Dépendance" }

      row = locals.first
      price = row["valeur_fonciere"].to_d
      built = row["surface_reelle_bati"].to_d
      carrez = (1..5).sum { |i| row["lot#{i}_surface_carrez"].to_d }
      area = carrez.positive? && (carrez - built).abs < built * CARREZ_TOLERANCE ? carrez : built
      next unless price.positive? && area.positive? && row["latitude"].present? && row["longitude"].present?

      Sale.new(
        date: Date.parse(row["date_mutation"]),
        price: price,
        area: area,
        latitude: row["latitude"].to_f,
        longitude: row["longitude"].to_f
      )
    rescue Date::Error
      nil
    end
  end

  # geo-DVF repeats a unit's row once per land-use subdivision of its parcel;
  # those repeats share everything but the land columns.
  def self.unit_key(row)
    row.values_at("id_parcelle", "numero_volume", "surface_reelle_bati", "nombre_pieces_principales",
                  *(1..5).map { |i| "lot#{i}_numero" })
  end

  def self.distance(lat1, lon1, lat2, lon2)
    rad = Math::PI / 180
    h = Math.sin((lat2 - lat1) * rad / 2)**2 +
        Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin((lon2 - lon1) * rad / 2)**2
    2 * EARTH_RADIUS * Math.asin(Math.sqrt(h))
  end

  def initialize(sales, latitude:, longitude:, area:, radius: DEFAULT_RADIUS)
    @sales = sales
    @latitude = latitude
    @longitude = longitude
    @area = area.to_d
    @radius = radius
  end

  # Returns an Estimate, or nil when no tier has enough comparable sales.
  def estimate
    return nil if sales.empty?

    TIERS.each do |tier|
      radius = self.radius * tier[:radius_factor]
      from = newest_date << tier[:months]
      comparables = sales.select do |sale|
        sale.date > from &&
          (sale.area - area).abs <= area * AREA_BAND &&
          self.class.distance(latitude, longitude, sale.latitude, sale.longitude) <= radius
      end
      next if comparables.size < MIN_SALES

      prices = comparables.map { |sale| sale.price_per_sqm * latest_level / level_at(sale.date) }.sort
      price_per_sqm = percentile(prices, 0.5)

      return Estimate.new(
        valuation: round_valuation(price_per_sqm),
        valuation_low: round_valuation(percentile(prices, 0.25)),
        valuation_high: round_valuation(percentile(prices, 0.75)),
        price_per_sqm: price_per_sqm.round,
        sales_count: comparables.size,
        radius: radius,
        months: tier[:months],
        confidence: tier[:confidence]
      )
    end

    nil
  end

  private
    attr_reader :sales, :latitude, :longitude, :area, :radius

    # DVF is published with a lag of six months or more, so windows end at the
    # newest sale in the data rather than today.
    def newest_date
      @newest_date ||= sales.map(&:date).max
    end

    # Median price per m² of each quarter across every sale loaded (whole
    # communes), so an older comparable counts at today's level, not its own.
    def quarter_levels
      @quarter_levels ||= sales.group_by { |sale| quarter(sale.date) }
                               .transform_values { |group| percentile(group.map(&:price_per_sqm).sort, 0.5) }
    end

    def latest_level
      @latest_level ||= begin
        since = newest_date << LATEST_LEVEL_MONTHS
        percentile(sales.select { |sale| sale.date > since }.map(&:price_per_sqm).sort, 0.5)
      end
    end

    def level_at(date)
      quarter_levels.fetch(quarter(date), latest_level)
    end

    def quarter(date)
      [ date.year, (date.month - 1) / 3 ]
    end

    # Linear interpolation between the closest ranks of a sorted list.
    def percentile(sorted, fraction)
      position = (sorted.size - 1) * fraction
      lower = sorted[position.floor]
      upper = sorted[position.ceil]
      lower + (upper - lower) * (position - position.floor)
    end

    def round_valuation(price_per_sqm)
      (price_per_sqm * area / 1000).round * 1000
    end
end
