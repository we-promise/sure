require "test_helper"

class DS::LocationPickerTest < ViewComponent::TestCase
  test "renders search state when the entry has no location" do
    entry = entries(:transaction)

    render_inline(DS::LocationPicker.new(form: form_builder_for(entry, "entry"), entry: entry))

    assert_selector "[data-location-picker-target='search']:not(.hidden)"
    assert_selector "[data-location-picker-target='display'].hidden"
  end

  test "renders display state when the entry already has a location" do
    entry = entries(:transaction)
    entry.assign_attributes(location_lat: 41.3851, location_lng: 2.1734, location_name: "Barcelona, Spain")

    render_inline(DS::LocationPicker.new(form: form_builder_for(entry, "entry"), entry: entry))

    assert_selector "[data-location-picker-target='display']:not(.hidden)"
    assert_text "Barcelona, Spain"
  end

  private
    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
