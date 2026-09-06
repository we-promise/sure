require "application_system_test_case"

class PropertiesEditTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    visit root_url
    open_new_account_modal
    create_new_property_account
  end

  test "can persist property subtype" do
    click_link_and_wait_for_render "[system test] Property Account"
    open_account_edit_dialog
    assert_field "account_accountable_attributes_subtype", with: "single_family_home"
  end

  private

    # The account link in the sidebar points at the page the app already
    # redirected to after creation, so Turbo keeps the outgoing body on screen
    # for the whole visit. Capybara happily finds the menu on that body and
    # opens the edit dialog into `#modal` — and then the visit renders and
    # replaces the body, taking the dialog with it. Waiting for the render
    # (see `click_link_and_wait_for_render`) is what makes this deterministic;
    # retrying the click just races the same render again.
    def open_account_edit_dialog
      within_testid("account-menu") do
        find("button").click
        click_on "Edit"
      end

      assert_selector "#account_accountable_attributes_subtype"
    end

    def open_new_account_modal
      within "[data-controller='DS--tabs']" do
        click_button "All"
        click_link "New account"
      end
    end

    def create_new_property_account
      click_link "Property"

      account_name = "[system test] Property Account"
      fill_in "Name*", with: account_name
      select "Single Family Home", from: "Property type*"
      fill_in "Year Built (optional)", with: 2005
      fill_in "Area (optional)", with: 2250

      click_button "Next"

      # Step 2: Enter balance information
      assert_text "Value"
      fill_in "account[balance]", with: 500000
      click_button "Next"

      # Step 3: Enter address information
      assert_text "Address"
      fill_in "Address Line 1", with: "123 Main St"
      fill_in "City", with: "San Francisco"
      fill_in "State/Region", with: "CA"
      fill_in "Postal Code", with: "94101"
      fill_in "Country", with: "US"

      click_button "Save"

      # Verify account was created and is now active
      assert_text account_name

      created_account = Account.order(:created_at).last
      assert_equal "active", created_account.status
      assert_equal 500000, created_account.balance
      assert_equal "123 Main St", created_account.property.address.line1
      assert_equal "San Francisco", created_account.property.address.locality
    end
end
