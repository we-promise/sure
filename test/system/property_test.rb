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
    click_link "[system test] Property Account"
    find("[data-testid='account-menu']").click
    click_on "Edit"
    assert_selector "#account_accountable_attributes_subtype"
    assert_selector(
        "#account_accountable_attributes_subtype option[selected]",
        text: "Single Family Home"
    )
  end

  private

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
