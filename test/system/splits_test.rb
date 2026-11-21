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

  test "edit dialog saves the merchant and tags picked with the DS pickers" do
    merchant = @user.family.merchants.create!(name: "Split Grocer")

    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        find("[data-merchant-select-target='button']").click
        find("[role='option'][data-merchant-name='#{merchant.name}']").click
        find("[data-tag-select-target='button']").click
        find("[role='option'][data-tag-name='#{tags(:one).name}']").click
      end

      click_button I18n.t("splits.edit.submit")
    end

    assert_text I18n.t("splits.update.success")

    child = @entry.reload.child_entries.find_by!(name: "Groceries")
    assert_equal merchant.id, child.entryable.merchant_id
    assert_equal [ tags(:one).id ], child.entryable.tag_ids
  end

  test "tag picker in a split row stays as tall as the other pickers" do
    visit edit_transaction_split_path(@entry)

    within "dialog" do
      within all("[data-split-transaction-target='row']", minimum: 2).first do
        assert_equal 1, picker_heights.uniq.size, "empty tag picker height differs: #{picker_heights}"

        find("[data-tag-select-target='button']").click
        find("[role='option'][data-tag-name='#{tags(:one).name}']").click
        find("[data-tag-select-target='selectionContainer']", text: tags(:one).name)

        assert_equal 1, picker_heights.uniq.size, "tag picker with a tag differs: #{picker_heights}"
      end
    end
  end

  private
    # Heights of the category, merchant and tag fields in the current split row.
    def picker_heights
      evaluate_script(<<~JS, current_scope)
        Array.from(arguments[0].querySelectorAll(".grid .form-field")).map((field) => Math.round(field.getBoundingClientRect().height))
      JS
    end
end
