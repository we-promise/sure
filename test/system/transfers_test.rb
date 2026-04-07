require "application_system_test_case"

class TransfersTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    visit transactions_url
  end

  test "can create a transfer" do
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    # Select accounts using DS::Select
    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:credit_card))

    fill_in "transfer[amount]", with: 500
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text "Payment to"
    end
  end

  private

    def select_ds(label_text, record)
      field_label = find("label", exact_text: label_text)
      container = field_label.ancestor("div.relative")

      # Click the button to open the dropdown
      container.find("button").click

      # If searchable, type in the search input
      if container.has_selector?("input[type='search']", visible: true)
        container.find("input[type='search']", visible: true).set(record.name)
      end

      # Wait for the listbox to appear inside the relative container
      listbox = container.find("[role='listbox']", visible: true)

      # Click the option inside the listbox
      listbox.find("[role='option'][data-value='#{record.id}']", visible: true).click
    end
end
