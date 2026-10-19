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
end
