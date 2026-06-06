require "test_helper"

class BalanceSheet::AccountGroupTest < ActiveSupport::TestCase
  # Minimal account double: only the surface AccountGroup#total/#weight use.
  StubAccount = Struct.new(:converted_balance, :include_in_finances) do
    def included_in_finances?
      include_in_finances
    end
  end

  test "total excludes accounts the user opted out of their finances" do
    group = BalanceSheet::AccountGroup.new(
      name: "Depository",
      color: "#000000",
      accountable_type: "Depository",
      accounts: [StubAccount.new(1000, true), StubAccount.new(2000, false)],
      classification_group: nil
    )

    # The excluded 2000 account must not be counted (mirrors ClassificationGroup).
    assert_equal 1000, group.total
  end

  test "weight is derived from the filtered total" do
    classification = Struct.new(:total).new(1000)
    group = BalanceSheet::AccountGroup.new(
      name: "Depository",
      color: "#000000",
      accountable_type: "Depository",
      accounts: [StubAccount.new(1000, true), StubAccount.new(2000, false)],
      classification_group: classification
    )

    # numerator (filtered group total) and denominator (already-filtered
    # classification total) are now consistent → 100%, not 300%.
    assert_in_delta 100.0, group.weight, 0.001
  end
end
