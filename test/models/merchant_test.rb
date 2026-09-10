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

  test "normalizes iban by stripping spaces and upcasing" do
    merchant = FamilyMerchant.new(name: "Landlord", family: families(:dylan_family), iban: "de89 3704 0044 0532 0130 00")
    merchant.valid?

    assert_equal "DE89370400440532013000", merchant.iban
  end

  test "leaves a blank iban as nil" do
    merchant = FamilyMerchant.new(name: "Landlord", family: families(:dylan_family), iban: "")
    merchant.valid?

    assert_nil merchant.iban
  end

  test "enforces uniqueness of iban per source for provider merchants" do
    ProviderMerchant.create!(name: "Existing Payee", source: "enable_banking", provider_merchant_id: "pm_1", iban: "AT611904300234573201")

    duplicate = ProviderMerchant.new(name: "Different Name", source: "enable_banking", provider_merchant_id: "pm_2", iban: "AT611904300234573201")

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end
end
