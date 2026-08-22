require "test_helper"

class CategoryListGroupViewTest < ActionView::TestCase
  test "loads transaction lookup in one query when no lookup is provided" do
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
      categories: [ category ],
      family: category.family
    })

    assert_includes html, new_category_deletion_path(category)
    assert_not_includes html, "data-turbo-method=\"delete\""
  end

  test "renders with empty categories when no transaction lookup is provided" do
    assert_nothing_raised do
      render(partial: "categories/category_list_group", locals: {
        title: "Categories",
        categories: []
      })
    end
  end
end
