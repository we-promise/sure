require "application_system_test_case"

class TransactionLocationTest < ApplicationSystemTestCase
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "setting a location via search and selecting a suggestion" do
    entry = create_transaction(account: accounts(:depository), name: "Travelodge Malaga", amount: 100)

    Geocoding::NominatimClient.any_instance.stubs(:search).returns(
      [ Geocoding::NominatimClient::Result.new(lat: 41.3851, lng: 2.1734, display_name: "Barcelona, Spain") ]
    )

    visit transaction_path(entry)
    find("summary", text: /#{I18n.t("transactions.show.details")}/i).click

    fill_in "Search a place...", with: "Barcelona"
    assert_text "Barcelona, Spain"
    find("li", text: "Barcelona, Spain").click

    # The hidden class comes off synchronously (before the Turbo Stream PATCH
    # fires), so this assertion alone doesn't prove the save completed — the
    # wait_until below is what actually waits for the real round trip.
    assert_selector "[data-location-picker-target='display']:not(.hidden)"

    wait_until { entry.reload.location_name == "Barcelona, Spain" }

    assert_equal "Barcelona, Spain", entry.location_name
    assert_equal 41.3851, entry.location_lat.to_f
    assert_equal 2.1734, entry.location_lng.to_f
  end

  test "selecting a suggestion with the keyboard sets the location" do
    entry = create_transaction(account: accounts(:depository), name: "Travelodge Malaga", amount: 100)

    Geocoding::NominatimClient.any_instance.stubs(:search).returns(
      [ Geocoding::NominatimClient::Result.new(lat: 41.3851, lng: 2.1734, display_name: "Barcelona, Spain") ]
    )

    visit transaction_path(entry)
    find("summary", text: /#{I18n.t("transactions.show.details")}/i).click

    # Looking the field up by its label is itself the check that the label is
    # associated with the input.
    search = find_field I18n.t("ds.location_picker.search_label")
    search.set("Barcelona")

    # Never touches the mouse: Tab out of the search field has to land on the
    # suggestion, and Enter there has to commit it.
    assert_text "Barcelona, Spain"
    option = find("[role='option']", text: "Barcelona, Spain")
    search.send_keys(:tab)
    assert_equal option.text, page.evaluate_script("document.activeElement.textContent")

    option.send_keys(:enter)

    wait_until { entry.reload.location_name == "Barcelona, Spain" }

    assert_equal "Barcelona, Spain", entry.location_name
  end

  test "dragging the confirm-map marker reverse-geocodes the new position" do
    entry = create_transaction(account: accounts(:depository), name: "Travelodge Malaga", amount: 100)

    Geocoding::NominatimClient.any_instance.stubs(:search).returns(
      [ Geocoding::NominatimClient::Result.new(lat: 41.3851, lng: 2.1734, display_name: "Barcelona, Spain") ]
    )
    # The dragged coordinates come from the marker, so only the name is
    # predictable here; the stub stands in for whatever Nominatim would answer.
    Geocoding::NominatimClient.any_instance.stubs(:reverse).returns(
      Geocoding::NominatimClient::Result.new(lat: 41.39, lng: 2.18, display_name: "Gràcia, Barcelona, Spain")
    )

    visit transaction_path(entry)
    find("summary", text: /#{I18n.t("transactions.show.details")}/i).click

    fill_in "Search a place...", with: "Barcelona"
    mark_header_stale(entry)
    find("li", text: "Barcelona, Spain").click

    wait_until { entry.reload.location_name == "Barcelona, Spain" }
    # Waiting on the database only proves the PATCH was handled. The drag is
    # only reachable if the confirm map outlives the *response* too, so wait for
    # the response's own streams to land before reaching for the marker —
    # otherwise a stream that replaces the picker races the assertions below and
    # the test passes by luck.
    assert_no_selector "##{dom_id(entry, :header)}[data-stale]"

    # The confirm map, its marker, and the marker's draggability all have to
    # survive that round trip — this is the regression that made drag-to-adjust
    # dead. The gesture itself is Leaflet's own code, so the test drives its
    # outcome rather than its pointer events (see #drag_marker_to).
    assert_selector "[data-location-picker-target='confirmMap'] .leaflet-marker-draggable"

    drag_marker_to(48.8566, 2.3522)

    wait_until { entry.reload.location_name == "Gràcia, Barcelona, Spain" }

    assert_equal "Gràcia, Barcelona, Spain", entry.location_name
    assert_equal 48.8566, entry.location_lat.to_f
    assert_equal 2.3522, entry.location_lng.to_f
  end

  private

    # Flags a node the update's turbo_stream response always replaces, so the
    # flag's disappearance means those streams have been applied.
    def mark_header_stale(entry)
      page.execute_script(
        "document.getElementById(arguments[0]).dataset.stale = 'true'",
        dom_id(entry, :header)
      )
    end

    # A real Selenium pointer drag does move the marker, but only about half the
    # time: the save's own turbo_stream replaces the header above the map, and a
    # layout shift between measuring the marker's box and pressing the mouse
    # lands the gesture on empty tile instead. Moving the marker and firing
    # `dragend` runs the whole #onDrag path — reverse-geocode request, stale-drag
    # guard, form submit — without racing the layout.
    def drag_marker_to(lat, lng)
      page.execute_script(<<~JS, lat, lng)
        const element = document.querySelector("[data-controller~='location-picker']");
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          element,
          "location-picker",
        );
        controller.marker.setLatLng([arguments[0], arguments[1]]);
        controller.marker.fire("dragend");
      JS
    end
end
