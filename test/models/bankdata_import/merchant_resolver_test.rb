# frozen_string_literal: true

require "test_helper"

class BankdataImport::MerchantResolverTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "returns nil for blank merchant names" do
    assert_nil BankdataImport::MerchantResolver.new(@family).resolve(nil)
    assert_nil BankdataImport::MerchantResolver.new(@family).resolve(" ")
  end

  test "reuses existing family merchant" do
    merchant = @family.merchants.create!(name: "Kuwait Petroleum")

    assert_equal merchant, BankdataImport::MerchantResolver.new(@family).resolve("Kuwait Petroleum")
  end

  test "creates family merchant" do
    merchant = BankdataImport::MerchantResolver.new(@family).resolve("Kuwait Petroleum")

    assert_predicate merchant, :persisted?
    assert_equal "Kuwait Petroleum", merchant.name
    assert_equal @family, merchant.family
  end
end
