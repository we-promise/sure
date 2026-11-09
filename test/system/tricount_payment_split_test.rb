# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/tricount_test_helper"

# A Tricount payment made with two card charges can't pair with either as one
# row. Split through the same dialog as a transaction, it becomes a row per
# part, each matchable; a part's row edits or undoes the split, like a split
# transaction's part.
class TricountPaymentSplitTest < ApplicationSystemTestCase
  include TricountTestHelper

  setup do
    @user = users(:family_admin)
    family = @user.family
    item = family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    tricount_account = item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)
    tricount_account.assign_member!(ME)
    @account = family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    tricount_account.ensure_account_provider!(@account)
    TricountAccount::Processor.new(tricount_account.reload).process
    @tricount_account = tricount_account
    sign_in @user
  end

  test "a payment splits through the transaction split dialog and a part undoes it" do
    payment = @account.entries.find_by!(external_id: "e1:paid")
    visit transaction_path(payment)
    find("summary", text: /#{I18n.t("transactions.show.settings")}/i).click
    assert_text I18n.t("splits.show.button_title")
    click_on I18n.t("splits.show.button")

    within("dialog[open]") { assert_selector "h2", text: "Dinner (you paid)" }
    within "dialog[open] [data-controller~='split-transaction']" do
      inputs = all("input[name$='[amount]']")
      assert_equal 2, inputs.size
      inputs[0].fill_in with: "60"
      assert_selector "[data-split-transaction-target='remaining']", text: "40.00"
      assert_button I18n.t("splits.new.submit"), disabled: true

      click_on I18n.t("splits.new.add_row")
      inputs = all("input[name$='[amount]']")
      assert_equal 3, inputs.size
      inputs[1].fill_in with: "25"
      inputs[2].fill_in with: "15"
      assert_selector "[data-split-transaction-target='remaining']", text: "0.00"
      click_on I18n.t("splits.new.submit")
    end

    assert_text I18n.t("tricount_items.payment_split.saved")
    assert_text "Dinner (you paid, part 1 of 3)"
    assert_text "Dinner (you paid, part 3 of 3)"
    assert_equal [ BigDecimal("-60"), BigDecimal("-25"), BigDecimal("-15") ], @account.entries.where("external_id LIKE 'e1:paid:%'").order(:external_id).pluck(:amount)

    # A part's row shows the whole payment with the split part's actions.
    visit transaction_path(@account.entries.find_by!(external_id: "e1:paid:2"))
    assert_text(/#{I18n.t("splits.child.title")}/i)
    assert_text "Dinner (you paid)"
    assert_link I18n.t("splits.child.edit_split")
    click_on I18n.t("splits.child.unsplit")
    within("#confirm-dialog") { find("button[value=confirm]", visible: true).click }

    assert_text I18n.t("tricount_items.payment_split.removed")
    assert_equal [ "e1:paid" ], @account.entries.where("external_id LIKE 'e1:paid%'").pluck(:external_id)
  end

  test "a part's row edits the split in the same dialog, prefilled" do
    @tricount_account.split_payment!("e1", [ "70.00", "30.00" ])
    visit transaction_path(@account.entries.find_by!(external_id: "e1:paid:1"))
    click_on I18n.t("splits.child.edit_split")

    within "dialog[open] [data-controller~='split-transaction']" do
      assert_equal [ "70.00", "30.00" ], all("input[name$='[amount]']").map(&:value)
      all("input[name$='[amount]']")[0].fill_in with: "50"
      all("input[name$='[amount]']")[1].fill_in with: "50"
      click_on I18n.t("splits.edit.submit")
    end

    assert_text I18n.t("tricount_items.payment_split.saved")
    assert_equal [ BigDecimal("-50"), BigDecimal("-50") ], @account.entries.where("external_id LIKE 'e1:paid:%'").order(:external_id).pluck(:amount)
  end
end
