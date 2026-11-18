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

    assert_equal "DE89370400440532013000", merchant.iban # pipelock:ignore IBAN
  end

  test "normalizes iban by stripping tabs and newlines" do
    merchant = FamilyMerchant.new(name: "Landlord", family: families(:dylan_family), iban: "de89\t3704\n0044 0532 0130 00")
    merchant.valid?

    assert_equal "DE89370400440532013000", merchant.iban # pipelock:ignore IBAN
  end

  test "normalizes iban by stripping dots, dashes, and other punctuation" do
    merchant = FamilyMerchant.new(name: "Landlord", family: families(:dylan_family), iban: "de89.3704-0044/0532:0130'00")
    merchant.valid?

    assert_equal "DE89370400440532013000", merchant.iban # pipelock:ignore IBAN
  end

  test "leaves a blank iban as nil" do
    merchant = FamilyMerchant.new(name: "Landlord", family: families(:dylan_family), iban: "")
    merchant.valid?

    assert_nil merchant.iban
  end

  test "allows the same iban across different sources for provider merchants" do
    ProviderMerchant.create!(name: "Existing Payee", source: "enable_banking", provider_merchant_id: "pm_1", iban: "AT611904300234573201") # pipelock:ignore IBAN

    other_source = ProviderMerchant.new(name: "Other Source Payee", source: "plaid", provider_merchant_id: "pm_2", iban: "AT611904300234573201") # pipelock:ignore IBAN

    assert other_source.valid?
  end

  test "allows the same iban across different families for family merchants" do
    FamilyMerchant.create!(name: "Landlord", family: families(:dylan_family), iban: "AT611904300234573201") # pipelock:ignore IBAN

    other_family = FamilyMerchant.new(name: "Landlord", family: families(:empty), iban: "AT611904300234573201") # pipelock:ignore IBAN

    assert other_family.valid?
  end

  test "allows the same iban on two merchants of one family" do
    FamilyMerchant.create!(name: "Alice Example", family: families(:dylan_family), iban: "AT611904300234573201") # pipelock:ignore IBAN

    joint_account_payer = FamilyMerchant.new(name: "Bob Example", family: families(:dylan_family), color: "#4da568", iban: "AT611904300234573201") # pipelock:ignore IBAN

    assert joint_account_payer.valid?
  end
end
