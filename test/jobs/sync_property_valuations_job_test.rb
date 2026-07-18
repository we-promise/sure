require "test_helper"

class SyncPropertyValuationsJobTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:property)
    @property = @account.property
    @property.update!(avm_provider: "rentcast")
  end

  def valuation_data(valuation: 600_000)
    Provider::PropertyValuationConcept::PropertyValuation.new(
      valuation: valuation,
      currency: "USD",
      property_type: "single_family_home",
      year_built: 1973,
      area_value: 1878,
      area_unit: "sqft"
    )
  end

  test "refreshes the valuation of linked properties via their provider" do
    provider = mock
    provider.stubs(:requests_remaining?).returns(true)
    provider.expects(:fetch_property_valuation).with(
      line1: "123 Main Street",
      locality: "Los Angeles",
      region: "CA",
      postal_code: "90001"
    ).returns(Provider::Response.new(success?: true, data: valuation_data, error: nil))
    Provider::Registry.stubs(:rentcast).returns(provider)

    SyncPropertyValuationsJob.new.perform

    assert_equal Date.current, @property.reload.avm_last_synced_on
    assert_equal 600_000, @account.reload.balance
  end

  test "skips properties already refreshed today" do
    @property.update!(avm_last_synced_on: Date.current)

    provider = mock
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    SyncPropertyValuationsJob.new.perform
  end

  test "skips refresh when the provider's monthly budget is spent" do
    provider = mock
    provider.stubs(:requests_remaining?).returns(false)
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    SyncPropertyValuationsJob.new.perform

    assert_nil @property.reload.avm_last_synced_on
  end

  test "skips properties whose provider is no longer configured" do
    Provider::Registry.stubs(:rentcast).returns(nil)

    SyncPropertyValuationsJob.new.perform

    assert_nil @property.reload.avm_last_synced_on
  end

  test "does not touch properties without an AVM provider" do
    @property.update!(avm_provider: nil)

    Provider::Registry.expects(:rentcast).never

    SyncPropertyValuationsJob.new.perform
  end
end
