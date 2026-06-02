require "test_helper"

class CategoryListGroupViewTest < ActionView::TestCase
  test "falls back to transaction existence checks when no lookup is provided" do
    category = categories(:food_and_drink)
    transaction = Transaction.create!(category: category)
    Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Fallback transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    html = render(partial: "categories/category_list_group", locals: {
      title: "Categories",
      categories: [ category ]
    })

    assert_includes html, new_category_deletion_path(category)
    assert_not_includes html, "data-turbo-method=\"delete\""
  end
end
