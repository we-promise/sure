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
    provider.stubs(:valuation_currency).returns("USD")
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
    assert_equal "RentCast valuation", @account.entries.valuations.find_by(date: Date.current).name
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
    provider.stubs(:valuation_currency).returns("USD")
    provider.stubs(:fetch_property_valuation).twice.returns(Provider::Response.new(success?: true, data: valuation_data, error: nil))
    Provider::Registry.expects(:rentcast).once.returns(provider)

    SyncPropertyValuationsJob.new.perform

    assert_equal Date.current, @property.reload.avm_last_synced_on
    assert_equal Date.current, second_account.property.reload.avm_last_synced_on
  end

  test "skips refresh when the account currency no longer matches the provider currency" do
    @account.update!(currency: "EUR")

    provider = mock
    provider.stubs(:requests_remaining?).returns(true)
    provider.stubs(:valuation_currency).returns("USD")
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
  end

  test "skips properties with incomplete addresses without spending a request" do
    @property.address.update!(region: "")

    Provider::Registry.expects(:rentcast).never

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
  end

  test "skips properties whose address city or ZIP was blanked" do
    @property.address.update!(locality: "")

    Provider::Registry.expects(:rentcast).never

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
  end

  test "skips properties whose address is no longer in the US" do
    @property.address.update!(country: "CA")

    Provider::Registry.expects(:rentcast).never

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
  end

  test "does not mark a property synced when the balance update fails" do
    provider = mock
    provider.stubs(:requests_remaining?).returns(true)
    provider.stubs(:valuation_currency).returns("USD")
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

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end

    assert_nil @property.reload.avm_last_synced_on
  end

  test "does not touch properties without an AVM provider" do
    @property.update!(avm_provider: nil)

    Provider::Registry.expects(:rentcast).never

    SyncPropertyValuationsJob.new.perform
  end

  # Chimnie (UK, UPRN-based) refreshes

  def create_uk_property(avm_last_synced_on: nil, uprn: "999000000001")
    @account.family.accounts.create!(
      name: "UK AVM Property",
      balance: 0,
      currency: "GBP",
      owner: @account.owner,
      accountable: Property.new(
        avm_provider: "chimnie",
        avm_external_id: uprn,
        avm_last_synced_on: avm_last_synced_on,
        address_attributes: { line1: "1 High Street", locality: "Chester", country: "GB", postal_code: "CH1 1MN" }
      )
    )
  end

  def gbp_valuation_data(valuation: 425_000)
    Provider::PropertyValuationConcept::PropertyValuation.new(
      valuation: valuation,
      currency: "GBP",
      property_type: nil,
      year_built: nil,
      area_value: nil,
      area_unit: "sqft",
      external_id: "999000000001"
    )
  end

  def stub_chimnie_provider
    provider = mock
    provider.stubs(:requests_remaining?).returns(true)
    provider.stubs(:valuation_currency).returns("GBP")
    Provider::Registry.stubs(:chimnie).returns(provider)
    provider
  end

  test "refreshes UK properties by UPRN and stores the valuation in GBP" do
    @property.update!(avm_provider: nil)
    uk_account = create_uk_property

    provider = stub_chimnie_provider
    provider.expects(:fetch_property_valuation).with(
      line1: "1 High Street",
      locality: "Chester",
      region: nil,
      postal_code: "CH1 1MN",
      external_id: "999000000001"
    ).returns(Provider::Response.new(success?: true, data: gbp_valuation_data, error: nil))

    SyncPropertyValuationsJob.new.perform

    uk_account.reload
    assert_equal 425_000, uk_account.balance
    assert_equal "GBP", uk_account.currency
    assert_equal "GBP", uk_account.entries.valuations.order(:date).last.currency
    assert_equal "Chimnie valuation", uk_account.entries.valuations.order(:date).last.name
    assert_equal Date.current, uk_account.property.avm_last_synced_on
  end

  test "does not refresh UK properties more than once a month" do
    @property.update!(avm_provider: nil)
    create_uk_property(avm_last_synced_on: Date.current - 2.weeks)

    provider = stub_chimnie_provider
    provider.expects(:fetch_property_valuation).never

    SyncPropertyValuationsJob.new.perform
  end

  test "refreshes UK properties again once a month has passed" do
    @property.update!(avm_provider: nil)
    uk_account = create_uk_property(avm_last_synced_on: Date.current - 1.month)

    provider = stub_chimnie_provider
    provider.expects(:fetch_property_valuation).once
      .returns(Provider::Response.new(success?: true, data: gbp_valuation_data, error: nil))

    SyncPropertyValuationsJob.new.perform

    assert_equal Date.current, uk_account.property.reload.avm_last_synced_on
  end

  test "a forced refresh of one property skips the refresh interval" do
    uk_account = create_uk_property(avm_last_synced_on: Date.current - 2.weeks)

    provider = stub_chimnie_provider
    provider.expects(:fetch_property_valuation).once
      .returns(Provider::Response.new(success?: true, data: gbp_valuation_data(valuation: 430_000), error: nil))
    Provider::Registry.expects(:rentcast).never

    SyncPropertyValuationsJob.new.perform(property_id: uk_account.property.id, force: true)

    assert_equal 430_000, uk_account.reload.balance
    assert_nil @property.reload.avm_last_synced_on
  end

  test "refreshing twice on the same date does not create a duplicate valuation" do
    @property.update!(avm_provider: nil)
    uk_account = create_uk_property

    provider = stub_chimnie_provider
    provider.stubs(:fetch_property_valuation)
      .returns(Provider::Response.new(success?: true, data: gbp_valuation_data(valuation: 425_000), error: nil))
      .then.returns(Provider::Response.new(success?: true, data: gbp_valuation_data(valuation: 431_000), error: nil))

    SyncPropertyValuationsJob.new.perform

    assert_no_difference -> { uk_account.entries.valuations.where(date: Date.current).count } do
      SyncPropertyValuationsJob.new.perform(property_id: uk_account.property.id, force: true)
    end

    assert_equal 431_000, uk_account.reload.balance
  end

  test "skips UK properties without a UPRN without spending a request" do
    @property.update!(avm_provider: nil)
    create_uk_property(uprn: nil)

    Provider::Registry.expects(:chimnie).never

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end
  end

  test "stops calling a provider for the rest of the run once it is rate limited" do
    @property.update!(avm_provider: nil)
    create_uk_property(uprn: "999000000001")
    create_uk_property(uprn: "999000000002")

    provider = stub_chimnie_provider
    provider.expects(:fetch_property_valuation).once.returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Chimnie::RateLimitError.new("Chimnie rate limit exceeded"))
    )

    assert_difference "DebugLogEntry.count" => 1 do
      SyncPropertyValuationsJob.new.perform
    end
  end
end
