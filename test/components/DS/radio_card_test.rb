require "test_helper"

class DS::RadioCardTest < ViewComponent::TestCase
  test "renders the shared card shell around the radio, label and hint" do
    render_radio_card(value: "date", checked: true)

    assert_selector "label.flex.items-start.gap-2.rounded-lg.border.border-primary.p-3.cursor-pointer"
    assert_selector "input[type='radio'][value='date']", visible: :all
    assert_selector "span.text-sm.font-medium.text-primary", text: "Fixed date"
    assert_selector "span.text-xs.text-secondary", text: "Sync from a specific date"
  end

  test "checks the radio when checked is true" do
    render_radio_card(value: "date", checked: true)

    assert page.find("input[type='radio']", visible: :all).checked?
  end

  test "leaves the radio unchecked when checked is false" do
    render_radio_card(value: "date", checked: false)

    assert_not page.find("input[type='radio']", visible: :all).checked?
  end

  test "merges an extra radio class without dropping the default" do
    render_radio_card(value: "date", checked: false, class: "extra-class")

    radio_class = page.find("input[type='radio']", visible: :all)[:class]
    assert_includes radio_class, "radio"
    assert_includes radio_class, "extra-class"
  end

  test "forwards data attributes to the radio input" do
    render_radio_card(value: "date", checked: false, data: { test_target: "radio" })

    assert_equal "radio", page.find("input[type='radio']", visible: :all)["data-test-target"]
  end

  private

    def render_radio_card(value:, checked:, **radio_opts)
      render_inline DS::RadioCard.new(
        form: form_builder_for(EnableBankingItem.new, "enable_banking_item"),
        method: :sync_strategy,
        value: value,
        label: "Fixed date",
        hint: "Sync from a specific date",
        checked: checked,
        **radio_opts
      )
    end

    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
