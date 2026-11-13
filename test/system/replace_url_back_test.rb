require "application_system_test_case"

class ReplaceUrlBackTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "Back after a tab switch restores the account page as it was left" do
    account = accounts(:investment)
    visit account_path(account)
    find("[role='tab']", text: "Holdings").click
    assert_current_path account_path(account, tab: "holdings")

    # Only the copy Turbo caches on leaving carries this mark. A refetch drops it.
    execute_script("document.body.dataset.left = ''")
    click_link "Transactions"
    assert_selector "main h1", text: "Transactions"

    page.go_back

    assert_selector "body[data-left]"
    assert_selector "[role='tab'][aria-selected='true']", text: "Holdings"
    assert_current_path account_path(account, tab: "holdings")
  end

  test "Back to a page that dropped its auto-open param shows that page" do
    visit settings_providers_path(manage: 1)
    assert_selector "details[open]", text: "SnapTrade"
    assert_current_path settings_providers_path

    click_link "Preferences"
    assert_selector "h1", text: "Preferences"

    page.go_back

    assert_selector "h1", text: "Bank sync"
    assert_current_path settings_providers_path
  end
end
