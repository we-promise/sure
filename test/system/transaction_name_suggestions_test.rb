require "application_system_test_case"

class TransactionNameSuggestionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false, auto_generate_transaction_names: true)
    sign_in @user
  end

  test "recent and searched names share one keyboard-accessible picker with category autofill" do
    visit new_transaction_url(account_id: accounts(:depository).id)
    find("#entry_name").click
    assert_selector ".hw-combobox [role='option']", text: "Starbucks"
    assert_selector "input[role='combobox']", count: 1

    fill_in "entry_name", with: "Starb"
    assert_selector ".hw-combobox [role='option']", text: "Starbucks"
    assert_selector ".hw-combobox [role='option']", count: 1
    find("#entry_name").send_keys(:arrow_down, :enter)
    assert_field "entry_name", with: "Starbucks"
    assert_category categories(:food_and_drink)

    fill_in "entry_name", with: "My custom purchase"
    find("input[name='entry[amount]']").set("12.34")
    click_button "Add transaction"
    assert_text "Transaction created"
    entry = @user.family.entries.order(created_at: :desc).first
    assert_equal "My custom purchase", entry.name
    assert_equal categories(:food_and_drink), entry.entryable.category
  end

  test "blank names keep the live category and merchant preview and save the generated name" do
    visit new_transaction_url(account_id: accounts(:depository).id)
    select_starbucks
    fill_in "entry_name", with: ""
    choose_category categories(:food_and_drink)
    assert_selector "#entry_name[placeholder='Food & Drink']"
    assert_field "entry_name", with: ""
    assert_no_selector "#entry_name[required]"

    find("summary", text: /details/i).click
    find("[data-merchant-select-target='button']").click
    find("[data-merchant-select-target='option'][data-merchant-id='#{merchants(:amazon).id}']").click
    assert_selector "#entry_name[placeholder='Food & Drink - Amazon']"
    find("input[name='entry[amount]']").set("12.34")
    click_button "Add transaction"
    assert_text "Transaction created"
    assert_equal "Food & Drink - Amazon", @user.family.entries.order(created_at: :desc).first.name
  end

  test "manual keyboard category selection and clearing survive subsequent name suggestions" do
    visit new_transaction_url(account_id: accounts(:depository).id)
    find("[data-category-select-target='button']").click
    fill_in "Search categories", with: "Income"
    find_field("Search categories").send_keys(:enter)
    select_starbucks
    assert_category categories(:income)

    choose_category nil
    select_starbucks
    assert_category nil
  end

  test "a prefilled category is not overwritten and names remain required when auto naming is off" do
    @user.family.update!(auto_generate_transaction_names: false)
    transactions(:one).update!(category: categories(:income))
    visit new_transaction_url(duplicate_entry_id: transactions(:one).entry.id)
    assert_selector "#entry_name[required]"
    assert_category categories(:income)
    select_starbucks
    assert_category categories(:income)
  end

  test "mobile picker selects a name and category without a second suggestions menu" do
    page.current_window.resize_to(390, 844)
    visit new_transaction_url(account_id: accounts(:depository).id)
    find("#entry_name").click

    within "dialog.hw-combobox__dialog" do
      find("input[role='combobox']").set("Starb")
      find("[role='option']", text: "Starbucks").click
    end

    assert_field "entry_name", with: "Starbucks"
    assert_category categories(:food_and_drink)
  end

  private
    def select_starbucks
      fill_in "entry_name", with: "Starb"
      find(".hw-combobox [role='option']", text: "Starbucks").click
      assert_field "entry_name", with: "Starbucks"
    end

    def choose_category(category)
      find("[data-category-select-target='button']").click
      find("[data-category-select-target='option'][data-category-id='#{category&.id}']").click
    end

    def assert_category(category)
      assert_selector "[data-category-select-target='hiddenInput'][value='#{category&.id}']", visible: :all
    end
end
