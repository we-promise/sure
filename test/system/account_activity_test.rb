require "application_system_test_case"

class AccountActivityTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)

    @account = accounts(:depository)
    @transaction_entry = @account.entries.create!(
      name: "Duplicate source",
      date: Date.current,
      amount: 42.50,
      currency: "USD",
      entryable: Transaction.new(category: categories(:food_and_drink))
    )
    @valuation_entry = @account.entries.create!(
      name: "Current balance",
      date: 1.day.ago.to_date,
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new
    )
  end

  test "account activity shows duplicate action for a selected transaction" do
    visit account_url(@account, tab: "activity")

    find("#" + dom_id(@transaction_entry, "selection")).check

    within "#entry-selection-bar" do
      assert_selector "a[title='Duplicate']:not(.hidden)"
    end
  end

  test "account activity hides duplicate action for a selected valuation" do
    visit account_url(@account, tab: "activity")

    find("#" + dom_id(@valuation_entry, "selection")).check

    within "#entry-selection-bar" do
      assert_selector "a[title='Duplicate'].hidden", visible: false
    end
  end

  test "account activity keeps long category names from overflowing the amount on mobile" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Amount On Mobile")

    page.current_window.resize_to(315, 643)

    visit account_url(@account, tab: "activity")

    row = find("##{dom_id(@transaction_entry)}")
    amount = row.find("p.privacy-sensitive", visible: true)
    category_name = row.find("#category_name_mobile_#{@transaction_entry.entryable.id}", visible: true)

    assert amount.visible?
    assert category_name.visible?

    row_rect = row.native.rect
    amount_rect = amount.native.rect
    viewport_width = page.evaluate_script("window.innerWidth")
    page_scroll_width = page.evaluate_script("document.documentElement.scrollWidth")

    assert_operator amount_rect.x + amount_rect.width, :<=, row_rect.x + row_rect.width
    assert_operator page_scroll_width, :<=, viewport_width
  end
end
