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
end
