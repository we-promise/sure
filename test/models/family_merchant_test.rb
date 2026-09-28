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

  test "find_or_create_with_name reuses an existing merchant instead of raising" do
    existing = FamilyMerchant.create!(family: @family, name: "Existing Merchant")

    merchant, created = FamilyMerchant.find_or_create_with_name(@family, "Existing Merchant", website_url: "https://ignored.example")

    assert_equal existing, merchant
    assert_not created
    assert_nil merchant.website_url
  end

  test "find_or_create_with_name creates a new merchant when none exists" do
    merchant, created = FamilyMerchant.find_or_create_with_name(@family, "Brand New Merchant", website_url: "https://new.example")

    assert created
    assert_equal "Brand New Merchant", merchant.name
    assert_equal "https://new.example", merchant.website_url
  end

  test "find_or_create_with_name recovers when a concurrent insert wins the race" do
    existing = FamilyMerchant.create!(family: @family, name: "Race Merchant")
    relation = @family.merchants

    relation.stub :find_by, nil do
      relation.stub :create!, ->(*) { raise ActiveRecord::RecordNotUnique, "duplicate key" } do
        merchant, created = FamilyMerchant.find_or_create_with_name(@family, "Race Merchant")

        assert_equal existing, merchant
        assert_not created
      end
    end
  end
end
