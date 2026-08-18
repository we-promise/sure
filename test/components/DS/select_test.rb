require "test_helper"

class DS::SelectTest < ViewComponent::TestCase
  test "falls back to the placeholder, not the include_blank item's own label, when nothing is selected" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      selected: nil,
      placeholder: "Select a Category",
      include_blank: "(none)"
    )

    assert_selector "button#parent_id_trigger", text: "Select a Category"
    refute_selector "button#parent_id_trigger", text: "(none)"
  end

  test "still shows the include_blank item's own label once it is explicitly selected" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      selected: 1,
      placeholder: "Select a Category",
      include_blank: "(none)"
    )

    assert_selector "button#parent_id_trigger", text: "Groceries"
  end

  private
    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
