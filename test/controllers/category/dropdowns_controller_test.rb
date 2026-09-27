require "test_helper"

class Category::DropdownsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @transaction = transactions(:one)
    ensure_tailwind_build
  end

  test "shows a recent section for categories used recently" do
    recent = categories(:income)
    recent.update!(last_used_at: 1.day.ago)

    get category_dropdown_url(transaction_id: @transaction.id)

    assert_response :success
    assert_select "[data-list-filter-target='recentSection']"
    assert_select "[data-list-filter-target='recentSection']", text: /#{Regexp.escape(recent.name)}/
  end

  test "recent and canonical rows for the same category have distinct DOM ids" do
    recent = categories(:income)
    recent.update!(last_used_at: 1.day.ago)

    get category_dropdown_url(transaction_id: @transaction.id)

    assert_response :success
    assert_select "##{dom_id(recent, 'recent_category_option')}", count: 1
    assert_select "##{dom_id(recent, 'category_option')}", count: 1
  end

  test "excludes the currently selected category from the recent section" do
    selected = categories(:food_and_drink)
    selected.update!(last_used_at: 1.day.ago)

    get category_dropdown_url(category_id: selected.id, transaction_id: @transaction.id)

    assert_response :success
    assert_select "[data-list-filter-target='recentSection']", false
  end

  test "omits the recent section entirely when nothing has been used yet" do
    get category_dropdown_url(transaction_id: @transaction.id)

    assert_response :success
    assert_select "[data-list-filter-target='recentSection']", false
  end

  test "renders a hidden create option wired to assign the new category to this transaction" do
    get category_dropdown_url(transaction_id: @transaction.id)

    assert_response :success
    assert_select "[data-controller~='category-quick-create'][data-category-quick-create-create-url-value=?]", categories_path(format: :json)
    assert_select "button.hidden[data-category-quick-create-target='createButton']"
    assert_select "form[data-category-quick-create-target='assignForm'][action=?]", transaction_category_path(@transaction.entry) do
      assert_select "input[name='entry[entryable_attributes][id]'][value=?]", @transaction.id.to_s
      assert_select "input[name='entry[entryable_attributes][category_id]'][data-category-quick-create-target='categoryIdField']"
    end
  end

  test "passes existing category names so the create option hides on an exact match" do
    get category_dropdown_url(transaction_id: @transaction.id)

    assert_response :success
    names_attr = css_select("[data-controller~='category-quick-create']").first["data-category-quick-create-existing-names-value"]
    assert_includes JSON.parse(names_attr), categories(:food_and_drink).name
  end

  test "offers only top-level categories as parents for a new subcategory" do
    get category_dropdown_url(transaction_id: @transaction.id)

    assert_response :success
    assert_select "button.hidden[data-category-quick-create-target='createAsSubcategory']"
    assert_select "[data-category-quick-create-target='parentPicker']" do
      assert_select "button[data-parent-id=?]", categories(:food_and_drink).id
      assert_select "button[data-parent-id=?]", categories(:subcategory).id, count: 0
    end
  end
end
