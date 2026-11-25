require "test_helper"

class Transactions::FiltersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "renders the filter menu inside the lazy-loaded turbo frame" do
    get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "turbo-frame#transaction-filters" do
      assert_select "#transaction-filters-menu"
    end
  end

  test "preserves active filters as checked state" do
    account = @user.accessible_accounts.alphabetically.first

    get filters_transactions_url(q: { accounts: [ account.name ] }),
        headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "input[type=checkbox][name='q[accounts][]'][value='#{account.name}'][checked]"
  end

  test "groups subcategories immediately after their parent in the category filter" do
    get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" }
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    checkbox_values = doc.css("input[name='q[categories][]']").map { |node| node["value"] }

    parent_index = checkbox_values.index(categories(:food_and_drink).name)
    child_index = checkbox_values.index(categories(:subcategory).name)

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "does not offer the balance updates filter, which only applies to an account's activity" do
    get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "#transaction-filters-menu button[data-id=?]", "balance_updates_filter", count: 0
  end

  test "offers the attachment filter in the filter menu" do
    get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "#transaction-filters-menu input[type=checkbox][name='q[attachment_status][]']", count: 2
  end

  test "preserves attachment and AI filter checked state" do
    get filters_transactions_url(q: { attachment_status: [ "with" ], ai_status: [ "history" ] }),
        headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "input[name='q[attachment_status][]'][value='with'][checked]"
    assert_select "input[name='q[attachment_status][]'][value='without'][checked]", count: 0
    assert_select "input[name='q[ai_status][]'][value='history'][checked]"
    assert_select "input[name='q[ai_status][]'][value='current'][checked]", count: 0
  end

  test "clear filters navigates the whole page outside the lazy frame" do
    get filters_transactions_url(q: { attachment_status: [ "with" ] }),
        headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "turbo-frame#transaction-filters" do
      assert_select "a[href=?][data-turbo-frame='_top']", transactions_path(clear_filters: true)
    end
  end

  test "filter menu loads the merchant list on demand and keeps selected merchants in the form" do
    get filters_transactions_url(q: { merchants: [ "Amazon" ] }),
        headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "turbo-frame#transaction-filters turbo-frame#merchant_filter_options[loading=lazy][data-action=?]", "turbo:frame-load->list-filter#filter" do
      assert_select "input[type=hidden][name='q[merchants][]'][value=?]", "Amazon"
    end
    assert_select "input[type=checkbox][name='q[merchants][]']", count: 0
  end

  test "requires authentication" do
    delete session_url(sessions(:one)) rescue nil
    reset!

    get filters_transactions_url
    assert_redirected_to new_session_url
  end
end
