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

  test "names the search input and the clear button for assistive tech" do
    entry = entries(:transaction)
    entry.assign_attributes(location_lat: 41.3851, location_lng: 2.1734, location_name: "Barcelona, Spain")

    render_inline(DS::LocationPicker.new(form: form_builder_for(entry, "entry"), entry: entry))

    input_id = page.find("[data-location-picker-target='searchInput']")[:id]
    assert_selector "label[for='#{input_id}']", text: I18n.t("ds.location_picker.search_label")

    # Without this the icon button announces as "X" — DS::Button's fallback
    # humanizes the icon key.
    assert_selector "[data-location-picker-target='display'] button[aria-label='#{I18n.t("ds.location_picker.clear_label")}']"

    # The list is labelled by the same label, so a screen reader announces what
    # the suggestions are for.
    assert_selector "[data-location-picker-target='suggestions'][role='listbox'][aria-labelledby='#{input_id}_label']"
  end

  test "disables the search input and clear button when can_annotate is false" do
    entry = entries(:transaction)

    render_inline(DS::LocationPicker.new(form: form_builder_for(entry, "entry"), entry: entry, can_annotate: false))

    assert_selector "[data-location-picker-target='searchInput'][disabled]"
    assert_selector "[data-location-picker-target='display'] button[disabled]"
  end

  test "does not disable the search input when can_annotate is true" do
    entry = entries(:transaction)

    render_inline(DS::LocationPicker.new(form: form_builder_for(entry, "entry"), entry: entry, can_annotate: true))

    assert_no_selector "[data-location-picker-target='searchInput'][disabled]"
  end

  private
    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
