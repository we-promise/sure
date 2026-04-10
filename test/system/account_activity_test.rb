require "application_system_test_case"

class AccountActivityTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)

    @account = accounts(:depository)
    @transaction_entry = @account.entries.create!(
      name: "Duplicate source",
      date: Date.current,
      amount: 42.50,
      currency: "USD",
      entryable: Transaction.new
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
end
