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

  test "does not render for a transaction on an account the member cannot access" do
    admin = users(:family_admin)
    private_account = admin.family.accounts.create!(name: "Admin Private Checking", owner: admin, balance: 0,
                                                    currency: "USD", accountable: Depository.new)
    private_entry = private_account.entries.create!(name: "Private", date: Date.current, amount: 10,
                                                    currency: "USD", entryable: Transaction.new)
    sign_in users(:family_member)

    get category_dropdown_url(transaction_id: private_entry.transaction.id)

    assert_response :not_found
  end
end
