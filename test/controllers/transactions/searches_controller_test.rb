require "test_helper"

class Transactions::SearchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "menu returns filter panel in turbo frame" do
    get search_menu_transactions_url

    assert_response :success
    assert_select "turbo-frame#transaction-filters-menu"
  end

  test "menu scopes filter inputs under q so the outer form submits them" do
    category = categories(:food_and_drink)
    get search_menu_transactions_url(q: { categories: [ category.name ] })

    assert_response :success
    assert_select "input[type=checkbox][name='q[categories][]'][checked=checked][value=?]",
      category.name
    assert_select "form", false, "menu fragment must not contain its own <form> (nested forms)"
  end
end
