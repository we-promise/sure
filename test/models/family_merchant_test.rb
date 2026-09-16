# frozen_string_literal: true

require "test_helper"

class FamilyMerchantTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "preserves user-selected color on creation" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Custom Color Merchant",
      color: "#123456"
    )

    assert_equal "#123456", merchant.color
  end

  test "sets random default color when color is blank" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Default Color Merchant"
    )

    assert_includes FamilyMerchant::COLORS, merchant.color
  end

  test "preserves existing color on update" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Original Merchant",
      color: "#123456"
    )

    merchant.update!(name: "Renamed Merchant")
    assert_equal "#123456", merchant.reload.color
  end

  test "replaces invalid hex color with default sample" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Invalid Color Merchant",
      color: "invalid-color"
    )

    assert_includes FamilyMerchant::COLORS, merchant.color
  end
end
