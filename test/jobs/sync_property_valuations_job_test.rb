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

  test "resolves each provider once per run across multiple properties" do
    second_account = @account.family.accounts.create!(
      name: "Second AVM Property",
      balance: 0,
      currency: "USD",
      owner: @account.owner,
      accountable: Property.new(
        avm_provider: "rentcast",
        address_attributes: { line1: "456 Oak Ave", locality: "Los Angeles", region: "CA", country: "US", postal_code: "90002" }
      )
    )

    provider = mock
    provider.stubs(:requests_remaining?).returns(true)
    provider.stubs(:fetch_property_valuation).twice.returns(Provider::Response.new(success?: true, data: valuation_data, error: nil))
    Provider::Registry.expects(:rentcast).once.returns(provider)

    SyncPropertyValuationsJob.new.perform

    assert_equal Date.current, @property.reload.avm_last_synced_on
    assert_equal Date.current, second_account.property.reload.avm_last_synced_on
  end

  test "skips properties with incomplete addresses without spending a request" do
    @property.address.update!(region: "")

    Provider::Registry.expects(:rentcast).never

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
  end

  test "does not mark a property synced when the balance update fails" do
    provider = mock
    provider.stubs(:requests_remaining?).returns(true)
    provider.stubs(:fetch_property_valuation).returns(Provider::Response.new(success?: true, data: valuation_data, error: nil))
    Provider::Registry.stubs(:rentcast).returns(provider)

    Account.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
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
