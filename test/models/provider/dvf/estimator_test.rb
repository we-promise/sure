require "test_helper"

class Provider::Dvf::EstimatorTest < ActiveSupport::TestCase
  LAT = 48.8546
  LON = 2.3973
  # About 111 m of latitude per 0.001°.
  NEAR = 0.001
  FAR = 0.006

  def sale(price_per_sqm:, date: Date.new(2025, 12, 1), area: 35, lat_offset: NEAR)
    Provider::Dvf::Estimator::Sale.new(
      date: date,
      price: (price_per_sqm * area).to_d,
      area: area.to_d,
      latitude: LAT + lat_offset,
      longitude: LON
    )
  end

  def estimate(sales, area: 35)
    Provider::Dvf::Estimator.new(sales, latitude: LAT, longitude: LON, area: area).estimate
  end

  def row(id:, type: "Appartement", price: "300000", built: "35", carrez: "", nature: "Vente", date: "2025-06-01", parcel: "75120000AB0001", lot: "")
    {
      "id_mutation" => id,
      "date_mutation" => date,
      "nature_mutation" => nature,
      "valeur_fonciere" => price,
      "type_local" => type,
      "surface_reelle_bati" => built,
      "lot1_surface_carrez" => carrez,
      "lot1_numero" => lot,
      "id_parcelle" => parcel,
      "latitude" => LAT.to_s,
      "longitude" => LON.to_s
    }
  end

  test "values the property at the median price per m² of nearby recent sales" do
    sales = (1..15).map { |i| sale(price_per_sqm: 8_000 + i * 100) }

    result = estimate(sales)

    assert_equal 8_800, result.price_per_sqm
    assert_equal 308_000, result.valuation
    assert_equal 15, result.sales_count
    assert_equal 500, result.radius
    assert_equal 12, result.months
    assert_equal "high", result.confidence
  end

  test "returns the interquartile range as the low and high valuations" do
    sales = (1..15).map { |i| sale(price_per_sqm: 8_000 + i * 100) }

    result = estimate(sales)

    assert_equal 296_000, result.valuation_low
    assert_equal 320_000, result.valuation_high
  end

  test "widens to 24 months, then to twice the radius, lowering the confidence" do
    recent = (1..10).map { sale(price_per_sqm: 9_000) }
    older = (1..5).map { sale(price_per_sqm: 9_000, date: Date.new(2024, 6, 1)) }
    assert_equal "medium", estimate(recent + older).confidence

    farther = (1..5).map { sale(price_per_sqm: 9_000, lat_offset: FAR) }
    result = estimate(recent + farther)
    assert_equal "low", result.confidence
    assert_equal 1_000, result.radius
  end

  test "returns nil when even the widest tier has too few sales" do
    assert_nil estimate((1..14).map { sale(price_per_sqm: 9_000) })
    assert_nil estimate([])
  end

  test "ignores sales whose area is far from the property's" do
    similar = (1..15).map { sale(price_per_sqm: 9_000) }
    large = (1..30).map { sale(price_per_sqm: 6_000, area: 120) }

    assert_equal 9_000, estimate(similar + large).price_per_sqm
  end

  test "brings older comparables to the latest price level" do
    # Prices rose 10% between the two halves of 2025.
    first_half = (1..15).map { sale(price_per_sqm: 9_000, date: Date.new(2025, 3, 1)) }
    second_half = (1..15).map { sale(price_per_sqm: 9_900, date: Date.new(2025, 11, 1)) }

    assert_equal 9_900, estimate(first_half + second_half).price_per_sqm
  end

  test "keeps single-property sales of the requested type" do
    rows = [
      row(id: "apartment"),
      row(id: "with_cellar"), row(id: "with_cellar", type: "Dépendance", built: ""),
      row(id: "two_apartments", lot: "1"), row(id: "two_apartments", lot: "2"),
      row(id: "with_shop"), row(id: "with_shop", type: "Local industriel. commercial ou assimilé"),
      row(id: "exchange", nature: "Echange"),
      row(id: "house", type: "Maison", built: "90"),
      row(id: "no_price", price: "")
    ]

    sales = Provider::Dvf::Estimator.sales_from_rows(rows, local_type: "Appartement")
    assert_equal 2, sales.size

    houses = Provider::Dvf::Estimator.sales_from_rows(rows, local_type: "Maison")
    assert_equal [ 90 ], houses.map(&:area)
  end

  test "counts a house once when its parcel is split across land uses" do
    rows = [
      row(id: "split", type: "Maison", built: "90"),
      row(id: "split", type: "Maison", built: "90"),
      row(id: "two_houses", type: "Maison", built: "90", parcel: "75120000AB0002"),
      row(id: "two_houses", type: "Maison", built: "90", parcel: "75120000AB0003")
    ]

    sales = Provider::Dvf::Estimator.sales_from_rows(rows, local_type: "Maison")

    assert_equal 1, sales.size
  end

  test "uses the Carrez area when it is close to the built area" do
    rows = [
      row(id: "carrez", built: "40", carrez: "36.5"),
      row(id: "other_lot", built: "40", carrez: "12")
    ]

    sales = Provider::Dvf::Estimator.sales_from_rows(rows, local_type: "Appartement")

    assert_equal [ 36.5, 40 ], sales.map { |s| s.area.to_f }
  end

  test "measures distances in meters" do
    assert_in_delta 111, Provider::Dvf::Estimator.distance(LAT, LON, LAT + NEAR, LON), 1
  end
end
