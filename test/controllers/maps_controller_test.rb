require "test_helper"

class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get map_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get map_url

    assert_response :success
  end

  test "excludes located entries from accounts the signed-in user cannot access" do
    family_member = users(:family_member)
    family_member.update!(preferences: (family_member.preferences || {}).merge("preview_features_enabled" => true))

    accessible_entry = accounts(:depository).entries.create!(
      name: "Travelodge Malaga", date: Date.current, amount: 100, currency: "EUR",
      location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain",
      entryable: Transaction.new
    )
    inaccessible_entry = accounts(:investment).entries.create!(
      name: "Hotel Barcelona", date: Date.current, amount: 150, currency: "EUR",
      location_lat: 41.38, location_lng: 2.17, location_name: "Barcelona, Spain",
      entryable: Transaction.new
    )

    sign_in family_member

    get map_url

    assert_response :success
    assert_match accessible_entry.id, response.body
    assert_no_match inaccessible_entry.id, response.body
  end

  test "excludes located entries belonging to a different family" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    own_entry = accounts(:depository).entries.create!(
      name: "Travelodge Malaga", date: Date.current, amount: 100, currency: "EUR",
      location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain",
      entryable: Transaction.new
    )

    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other family account", balance: 0, currency: "EUR", accountable: Depository.new)
    other_entry = other_account.entries.create!(
      name: "Hotel Barcelona", date: Date.current, amount: 150, currency: "EUR",
      location_lat: 41.38, location_lng: 2.17, location_name: "Barcelona, Spain",
      entryable: Transaction.new
    )

    get map_url

    assert_response :success
    assert_match own_entry.id, response.body
    assert_no_match other_entry.id, response.body
  end

  test "account_id param filters located entries to that account" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    account = accounts(:depository)
    other_account = accounts(:credit_card)
    in_account = account.entries.create!(
      name: "Travelodge Malaga", date: Date.current, amount: 100, currency: "EUR",
      location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain",
      entryable: Transaction.new
    )
    in_other_account = other_account.entries.create!(
      name: "Hotel Barcelona", date: Date.current, amount: 150, currency: "EUR",
      location_lat: 41.38, location_lng: 2.17, location_name: "Barcelona, Spain",
      entryable: Transaction.new
    )

    get map_url(account_id: account.id)

    assert_match in_account.id, response.body
    assert_no_match in_other_account.id, response.body
  end
end
