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
end
