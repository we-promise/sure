require "application_system_test_case"

class SplitsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = create_transaction(amount: 100, name: "Split layout", account: accounts(:depository))
    @entry.split!([ { name: "Groceries", amount: 70 }, { name: "Household", amount: 30 } ])
  end

  test "edit dialog keeps each split row's category, merchant and tag pickers inside the row" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      rows = all("[data-split-transaction-target='row']", minimum: 2)

      rows.each do |row|
        overflow = page.evaluate_script("arguments[0].scrollWidth - arguments[0].clientWidth", row)
        assert_operator overflow, :<=, 0, "split row content overflows its row by #{overflow}px"
      end
    end
  end
end
