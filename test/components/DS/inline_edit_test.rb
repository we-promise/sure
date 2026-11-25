require "test_helper"

class DS::InlineEditTest < ViewComponent::TestCase
  test "renders a content-sized inline input with a pencil affordance" do
    render_inline(DS::InlineEdit.new(form: form_builder, method: :name, value: "Sent to Nancy", aria_label: "Transaction name"))

    assert_selector "label[for='preview_name'] input#preview_name[name='preview[name]'][value='Sent to Nancy']"
    assert_selector "label[for='preview_name'] input.field-sizing-content.text-right"
    assert_selector "label[for='preview_name'] input[required][aria-label='Transaction name']"
    assert_selector "label[for='preview_name'] svg"
  end

  test "forwards data and extra classes to the input" do
    render_inline(DS::InlineEdit.new(
      form: form_builder,
      method: :name,
      value: "Sent to Nancy",
      aria_label: "Transaction name",
      class: "custom-input",
      data: { auto_submit_form_target: "auto" }
    ))

    assert_selector "input.custom-input[data-auto-submit-form-target='auto']"
  end

  test "sizes to the value with a small minimum" do
    render_inline(DS::InlineEdit.new(form: form_builder, method: :name, value: "A", aria_label: "Transaction name"))
    assert_selector "input[size='4']"

    render_inline(DS::InlineEdit.new(form: form_builder, method: :name, value: "Sent to Nancy", aria_label: "Transaction name"))
    assert_selector "input[size='13']"
  end

  private
    def form_builder
      StyledFormBuilder.new(:preview, nil, vc_test_controller.view_context, {})
    end
end
