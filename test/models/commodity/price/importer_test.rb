require "test_helper"

class Commodity::Price::ImporterTest < ActiveSupport::TestCase
  ProviderPrice = Commodity::Price::Provided::ProviderPrice

  setup do
    travel_to Time.zone.local(2026, 10, 15, 18)
    @gold = Commodity.metal("XAU")
  end

  test "backfills from the start date and carries prices over weekends" do
    friday = Date.new(2026, 10, 9)
    monday = Date.new(2026, 10, 12)
    Commodity::Price.expects(:fetch_provider_prices).returns("XAU" => [
      provider_price(friday, 2600), provider_price(monday, 2610), provider_price(Date.new(2026, 10, 15), 2625)
    ])

    import(start_date: friday)

    prices = Commodity::Price.where(code: "XAU").order(:date).pluck(:date, :price, :provisional)
    assert_equal friday..Date.new(2026, 10, 15), prices.first[0]..prices.last[0]
    assert_equal 7, prices.size
    saturday = prices.find { |d, *| d == Date.new(2026, 10, 10) }
    assert_equal [ BigDecimal("2600"), true ], saturday[1..]
    assert_equal [ BigDecimal("2625"), true ], prices.last[1..] # today's price is intraday, refreshed later
  end

  test "leaves an honest gap before the first known price" do
    Commodity::Price.expects(:fetch_provider_prices).returns("XAU" => [ provider_price(Date.new(2026, 10, 14), 2620) ])

    import(start_date: Date.new(2026, 10, 1))

    assert_equal Date.new(2026, 10, 14), Commodity::Price.where(code: "XAU").minimum(:date)
  end

  test "skips the provider when every day is already stored" do
    (Date.new(2026, 10, 13)..Date.new(2026, 10, 15)).each do |date|
      Commodity::Price.create!(code: "XAU", date: date, price: 2600, currency: "USD", source: "gold_api")
    end
    Commodity::Price.expects(:fetch_provider_prices).never

    assert_equal 0, import(start_date: Date.new(2026, 10, 13))
  end

  test "keeps a stored spot price when a later fetch only has futures for that day" do
    Commodity::Price.create!(code: "XAU", date: Date.new(2026, 10, 14), price: 2620, currency: "USD", source: "gold_api", provisional: true, updated_at: 2.hours.ago)
    Commodity::Price.expects(:fetch_provider_prices).returns("XAU" => [
      provider_price(Date.new(2026, 10, 14), 2650, source: "yahoo_futures"), provider_price(Date.new(2026, 10, 15), 2630)
    ])

    import(start_date: Date.new(2026, 10, 14))

    kept = Commodity::Price.find_by!(code: "XAU", date: Date.new(2026, 10, 14))
    assert_equal [ BigDecimal("2620"), "gold_api", false ], [ kept.price, kept.source, kept.provisional ]
  end

  private
    def import(start_date:)
      Commodity::Price::Importer.new(metals: [ @gold ], start_date: start_date, end_date: Date.current).import
    end

    def provider_price(date, price, source: "gold_api")
      ProviderPrice.new(code: "XAU", date: date, price: BigDecimal(price.to_s), currency: "USD", source: source)
    end
end
