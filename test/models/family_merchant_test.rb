require "test_helper"

class FamilyMerchantTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "keeps explicitly chosen color on create" do
    merchant = @family.merchants.create!(name: "Chosen Color Shop", color: "#6471eb")

    assert_equal "#6471eb", merchant.color
  end

  test "assigns a default color when none is provided" do
    merchant = @family.merchants.create!(name: "No Color Shop")

    assert_includes FamilyMerchant::COLORS, merchant.color
  end

  test "assigns a default color when color is blank" do
    merchant = @family.merchants.create!(name: "Blank Color Shop", color: "")

    assert_includes FamilyMerchant::COLORS, merchant.color
  end

  test "does not reshuffle color when updating other attributes" do
    merchant = @family.merchants.create!(name: "Stable Color Shop")
    original_color = merchant.color

    merchant.update!(name: "Stable Color Shop Renamed")

    assert_equal original_color, merchant.reload.color
  end

  test "keeps newly selected color on update" do
    merchant = @family.merchants.create!(name: "Recolored Shop")

    merchant.update!(color: "#db5a54")

    assert_equal "#db5a54", merchant.reload.color
  end
end
