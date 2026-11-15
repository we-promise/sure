require "test_helper"

class PropertyTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:property)
    @property = @account.property
  end

  test "names the day's reconciliation after the AVM provider" do
    @property.update!(avm_provider: "chimnie")
    @account.set_current_balance(560_000)

    @property.name_avm_valuation!

    assert_equal "Chimnie valuation", @account.entries.valuations.find_by(date: Date.current).name
  end

  test "a later manual edit on the same day drops the provider label" do
    @property.update!(avm_provider: "chimnie")
    @account.set_current_balance(560_000)
    @property.name_avm_valuation!
    entry = @account.entries.valuations.find_by(date: Date.current)

    @account.update_reconciliation(entry, balance: 570_000, date: Date.current)

    assert_equal "Manual value update", entry.reload.name
    assert_equal 570_000, entry.amount
  end

  test "leaves manual value updates alone for properties without a provider" do
    @property.update!(avm_provider: nil)
    @account.set_current_balance(560_000)

    @property.name_avm_valuation!

    assert_equal "Manual value update", @account.entries.valuations.find_by(date: Date.current).name
  end

  test "does not rename opening or current anchors" do
    @property.update!(avm_provider: "rentcast")
    entry = @account.entries.create!(
      date: Date.current,
      name: "Original purchase price",
      amount: 500_000,
      currency: @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @property.name_avm_valuation!

    assert_equal "Original purchase price", entry.reload.name
  end

  test "link_avm_provider! never clears a link another request already made" do
    property = accounts(:property).property
    property.update!(avm_provider: nil)
    stale = Property.find(property.id)
    Provider::Registry.stubs(:rentcast).returns(mock)
    Property.where(id: property.id).update_all(avm_provider: "realie", avm_last_synced_on: Date.current)

    SyncPropertyValuationsJob.expects(:perform_now).never
    assert_not stale.link_avm_provider!("rentcast")

    property.reload
    assert_equal "realie", property.avm_provider
    assert_equal Date.current, property.avm_last_synced_on
  end

  test "a French property can link to DVF only with an area and a type it can value" do
    property = Property.new(
      subtype: "apartment",
      area_value: 35,
      area_unit: "sqm",
      address: Address.new(line1: "82 rue Exemple", postal_code: "75020", country: "France")
    )
    property.account = Account.new(currency: "EUR", accountable: property)

    assert property.avm_linkable?("dvf")

    property.area_value = nil
    assert_not property.avm_linkable?("dvf")

    property.area_value = 35
    property.subtype = "commercial"
    assert_not property.avm_linkable?("dvf")

    property.subtype = "apartment"
    property.account.currency = "USD"
    assert_not property.avm_linkable?("dvf")
  end

  test "family currency trend converts the purchase at its date's rate and the value at today's" do
    purchase_date = 2.years.ago.to_date
    setup_foreign_property(purchase_date: purchase_date, purchase: 100_000, current: 110_000)
    store_rate("USD", "EUR", purchase_date, 1.0)
    store_rate("USD", "EUR", Date.current, 0.9)

    trend = @property.family_currency_trend

    # +10% in USD, but the dollar fell 10% against the euro: about -1% in EUR.
    assert_equal Money.new(100_000, "EUR"), trend.previous
    assert_equal Money.new(99_000, "EUR"), trend.current
    assert_equal Money.new(-1_000, "EUR"), trend.value
    assert_equal(-1.0, trend.percent)
    # The trend in the account's own currency is unchanged.
    assert_equal 10.0, @property.trend.percent
  end

  test "family currency trend uses the latest earlier stored rate, however old" do
    purchase_date = Date.new(2024, 3, 10)
    setup_foreign_property(purchase_date: purchase_date, purchase: 100_000, current: 100_000)
    store_rate("USD", "EUR", purchase_date - 30, 0.7)
    store_rate("USD", "EUR", purchase_date - 10, 0.8)
    store_rate("USD", "EUR", purchase_date + 1, 0.5)
    store_rate("USD", "EUR", Date.current - 2, 0.9)
    ExchangeRate.expects(:provider).never

    trend = @property.family_currency_trend

    assert_equal Money.new(80_000, "EUR"), trend.previous
    assert_equal Money.new(90_000, "EUR"), trend.current
  end

  test "family currency trend uses the earliest later stored rate when none is earlier" do
    purchase_date = Date.new(2024, 3, 10)
    setup_foreign_property(purchase_date: purchase_date, purchase: 100_000, current: 100_000)
    store_rate("USD", "EUR", purchase_date + 3, 0.8)
    store_rate("USD", "EUR", purchase_date + 20, 0.5)
    ExchangeRate.expects(:provider).never

    trend = @property.family_currency_trend

    assert_equal Money.new(80_000, "EUR"), trend.previous
    assert_equal Money.new(50_000, "EUR"), trend.current
  end

  test "family currency trend is unavailable without any stored rate and never fetches one" do
    setup_foreign_property(purchase_date: 2.years.ago.to_date, purchase: 100_000, current: 110_000)
    store_rate("USD", "GBP", Date.current, 0.8)
    ExchangeRate.expects(:provider).never

    assert @property.family_currency_trend_applicable?
    assert_nil @property.family_currency_trend
  end

  test "family currency trend does not apply when the property is in the family currency" do
    @account.family.update!(currency: "USD")

    assert_not @property.family_currency_trend_applicable?
    assert_nil @property.family_currency_trend
  end

  test "the purchase valuation is looked up once and again after a reload" do
    setup_foreign_property(purchase_date: 2.years.ago.to_date, purchase: 100_000, current: 110_000)

    # Uncached, so the request's query cache does not hide a repeat.
    ActiveRecord::Base.uncached do
      assert_queries_match(/FROM "entries"/, count: 1) do
        @property.family_currency_trend_applicable?
        @property.family_currency_trend
        @property.purchase_price
      end
    end

    @account.entries.create!(
      date: 3.years.ago.to_date, name: "Earlier", amount: 90_000, currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    assert_equal 90_000, @property.reload.purchase_price.amount
  end

  private
    def setup_foreign_property(purchase_date:, purchase:, current:)
      @account.family.update!(currency: "EUR")
      @account.entries.valuations.destroy_all
      @account.entries.create!(
        date: purchase_date,
        name: "Original purchase price",
        amount: purchase,
        currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      @account.update!(balance: current)
      @property.reload
    end

    def store_rate(from, to, date, rate)
      ExchangeRate.create!(from_currency: from, to_currency: to, date: date, rate: rate)
    end
end
