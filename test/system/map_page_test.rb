require "application_system_test_case"

class MapPageTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "renders a map with a marker for a located transaction" do
    create_transaction(
      account: accounts(:depository),
      name: "Travelodge Malaga",
      amount: 100
    ).update!(location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain")

    visit map_path

    assert_selector ".leaflet-container"
    # One point gets a plain marker, not a cluster, and the icon image has to
    # resolve from the locally vendored asset rather than Leaflet's CDN default.
    marker = find(".leaflet-marker-icon:not(.marker-cluster)")
    wait_until { page.evaluate_script("arguments[0].complete && arguments[0].naturalWidth > 0", marker) }
    assert_equal true, page.evaluate_script("arguments[0].complete && arguments[0].naturalWidth > 0", marker)

    marker.click
    assert_link "Travelodge Malaga", href: transaction_path(Entry.find_by(location_name: "Malaga, Spain"))

    within "main" do
      assert_link "Travelodge Malaga", href: transaction_path(Entry.find_by(location_name: "Malaga, Spain")), count: 2
    end
  end

  test "hovering a list row highlights its location on the map" do
    create_transaction(
      account: accounts(:depository),
      name: "Travelodge Malaga",
      amount: 100
    ).update!(location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain")

    visit map_path

    # The highlight is an SVG circle in the overlay pane, distinct from the
    # marker icons (img elements in the marker pane) already on the page.
    assert_no_selector ".leaflet-overlay-pane path"

    find("li", text: "Travelodge Malaga").hover
    assert_selector ".leaflet-overlay-pane path"

    page.find("body").hover
    assert_no_selector ".leaflet-overlay-pane path"
  end
end
