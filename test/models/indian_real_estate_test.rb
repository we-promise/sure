require "test_helper"

class IndianRealEstateTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = @family.users.first
  end

  test "classification returns asset" do
    assert_equal "asset", IndianRealEstate.classification
  end

  test "icon returns building" do
    assert_equal "building", IndianRealEstate.icon
  end

  test "color returns correct hex" do
    assert_equal "#059669", IndianRealEstate.color
  end

  test "SUBTYPES contains property types" do
    expected_subtypes = %w[apartment plot commercial_property rented_property under_construction agricultural_land]
    expected_subtypes.each do |subtype|
      assert IndianRealEstate::SUBTYPES.key?(subtype), "Missing subtype: #{subtype}"
    end
  end

  test "Agricultural land is tax exempt" do
    property = IndianRealEstate.new(subtype: "agricultural_land")
    assert_equal :tax_exempt, property.tax_treatment
  end

  test "Apartment is taxable" do
    property = IndianRealEstate.new(subtype: "apartment")
    assert_equal :taxable, property.tax_treatment
  end

  test "subtypes_grouped_for_select returns grouped options" do
    grouped = IndianRealEstate.subtypes_grouped_for_select
    assert grouped.is_a?(Array)
    assert_equal 1, grouped.size
  end

  test "can create account with accountable" do
    account = @family.accounts.create!(
      accountable: IndianRealEstate.new(
        subtype: "apartment",
        area_value: "1500",
        area_unit: "sqft",
        registration_number: "ABC/1234/2024"
      ),
      name: "My Apartment",
      balance: 10000000,
      currency: "INR"
    )

    assert account.persisted?
    assert_equal "apartment", account.subtype
    assert_in_delta 1500, account.accountable.area_value.to_d, 0.001
  end

  test "area returns measurement object" do
    property = IndianRealEstate.new(area_value: "1500", area_unit: "sqft")
    area = property.area
    assert area.is_a?(Measurement)
    assert_equal 1500, area.value
    assert_equal "sqft", area.unit
  end
end
