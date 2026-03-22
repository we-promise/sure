require "application_system_test_case"

class DragAndDropImportTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "upload csv via hidden input on transactions index" do
    visit transactions_path

    assert_selector "#transactions[data-controller*='drag-and-drop-import']"
    assert_selector "form[action='#{imports_path}']"
    assert_selector "input[name='import[import_file]']", visible: :all

    # We can't easily simulate a true native drag-and-drop in headless chrome via Capybara without complex JS.
    # However, we can verify that the hidden form exists and works when a file is "dropped" (input populated).
    # The Stimulus controller's job is just to transfer the dropped file to the input and submit.

    file_path = file_fixture("imports/transactions.csv")

    attach_file "import[import_file]", file_path, make_visible: true

    # Submit the form manually since we bypassed the 'drop' event listener which triggers submit
    find("form[action='#{imports_path}']").evaluate_script("this.requestSubmit()")

    # Redirect lands on configuration step; flash may not be visible in CI
    assert_text "Configure your import"
  end
end
