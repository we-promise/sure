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
    visit account_url(@property_account)
    assert_text "Estimated property value", wait: 10

    open_account_edit_dialog

    assert_selector "dialog[open]", wait: 10
    assert_selector "#account_accountable_attributes_subtype option[selected][value='single_family_home']", wait: 10
  end

  private

    # The account page issues a Turbo morph refresh shortly after it loads
    # (`turbo_refreshes_with method: :morph` reacting to a family-stream
    # broadcast). If the edit modal is opened while that refresh is in flight,
    # the morph re-renders the page and wipes the just-loaded `#modal`
    # turbo-frame before the dialog is interactive. Open via the account menu and
    # retry once the refresh has settled so the test is deterministic instead of
    # racing the broadcast.
    def open_account_edit_dialog
      3.times do
        within_testid("account-menu") do
          find("button").click
          click_on "Edit"
        end
        return if has_selector?("dialog[open] #account_accountable_attributes_subtype", wait: 2)
      end
      assert_selector "dialog[open] #account_accountable_attributes_subtype"
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

      @property_account = Account.order(:created_at).last
      assert_equal "active", @property_account.status
      assert_equal 500000, @property_account.balance
      assert_equal "123 Main St", @property_account.property.address.line1
      assert_equal "San Francisco", @property_account.property.address.locality
    end
end
