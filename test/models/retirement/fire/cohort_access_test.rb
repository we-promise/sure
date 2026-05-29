require "test_helper"

class Retirement::Fire::CohortAccessTest < ActiveSupport::TestCase
  CA = Retirement::Fire::CohortAccess

  test "UK NMPA rises to 57 for cohorts reaching 57 in 2028+" do
    # turns 57 in 2027 -> 55; turns 57 in 2028 -> 57
    assert_equal 55, CA.min_access_age(country: "UK", pension_system: "uk_workplace", birth_year: 1970)
    assert_equal 57, CA.min_access_age(country: "UK", pension_system: "uk_workplace", birth_year: 1972)
  end

  test "UK protected pre-2021 keeps 55" do
    assert_equal 55, CA.min_access_age(country: "UK", pension_system: "uk_workplace", birth_year: 1980, protected_pre_2021: true)
  end

  test "US 401k/IRA is 59.5, SS is 62" do
    assert_equal 59.5, CA.min_access_age(country: "US", pension_system: "custom", birth_year: 1980)
    assert_equal 62, CA.min_access_age(country: "US", pension_system: "us_ss", birth_year: 1980)
  end

  test "DE GRV early access 63, otherwise 55" do
    assert_equal 63, CA.min_access_age(country: "DE", pension_system: "de_grv", birth_year: 1980)
    assert_equal 55, CA.min_access_age(country: "DE", pension_system: "de_bav", birth_year: 1980)
  end

  test "override wins" do
    assert_equal 50, CA.min_access_age(country: "DE", pension_system: "de_grv", birth_year: 1980, override: 50)
  end
end
