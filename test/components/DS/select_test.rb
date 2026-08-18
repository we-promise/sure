require "test_helper"

class DS::SelectTest < ViewComponent::TestCase
  test "child? is true for an item whose object has a present parent_id" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:subcategory) ]
    )

    item = select.items.first
    assert select.child?(item)
  end

  test "child? is false for an item whose object has no parent_id" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:food_and_drink) ]
    )

    item = select.items.first
    assert_not select.child?(item)
  end

  test "child? is false for objects that don't respond to parent_id" do
    select = DS::Select.new(
      form: nil,
      method: :merchant_id,
      items: [ merchants(:netflix) ]
    )

    item = select.items.first
    assert_not select.child?(item)
  end

  test "child? is false for the include_blank placeholder item" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:subcategory) ],
      include_blank: "Uncategorized"
    )

    blank_item = select.items.first
    assert_nil blank_item[:object]
    assert_not select.child?(blank_item)
  end

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
