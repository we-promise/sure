require "test_helper"

class Category::DropdownsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @transaction = transactions(:one)
  end

  test "shows an add category link for a search with no matches" do
    get category_dropdown_url, params: {
      category_id: @transaction.category_id,
      transaction_id: @transaction.id
    }

    assert_response :success
    assert_select "a[data-list-filter-target='addItem'][data-turbo-frame='modal']", count: 1
    assert_select "a[data-list-filter-target='addItem'][href*='transaction_id=#{@transaction.id}']", count: 1
    assert_select "[data-list-filter-target='addText']", count: 1
  end
end
