require "test_helper"

class MerchantTest < ActiveSupport::TestCase
  test "rejects the reserved No merchant filter sentinel as a name" do
    merchant = FamilyMerchant.new(name: Merchant::NO_MERCHANT_FILTER_VALUE, family: families(:dylan_family))

    assert_not merchant.valid?
    assert_includes merchant.errors[:name], "is reserved"
  end

  test "filter_value returns the sentinel for the synthetic No merchant merchant and the name for real merchants" do
    assert_equal Merchant::NO_MERCHANT_FILTER_VALUE, Merchant.no_merchant.filter_value
    assert_equal merchants(:netflix).name, merchants(:netflix).filter_value
  end
end
