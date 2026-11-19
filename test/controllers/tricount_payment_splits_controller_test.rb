# frozen_string_literal: true

require "test_helper"
require_relative "../support/tricount_test_helper"

class TricountPaymentSplitsControllerTest < ActionDispatch::IntegrationTest
  include TricountTestHelper

  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
    item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @tricount_account = item.tricount_accounts.new
    @tricount_account.upsert_from_tricount!(tricount_registry)
    @tricount_account.assign_member!(ME)
    @account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    @tricount_account.ensure_account_provider!(@account)
    TricountAccount::Processor.new(@tricount_account.reload).process
    @payment = @account.entries.find_by!(external_id: "e1:paid")
  end

  test "the payment's drawer offers to split it, its share's doesn't" do
    get transaction_url(@payment)
    assert_select "a[href='#{new_tricount_payment_split_path(@payment)}']", text: I18n.t("splits.show.button")

    share = @account.entries.find_by!(external_id: "e1:share")
    get transaction_url(share)
    assert_select "a[href='#{new_tricount_payment_split_path(share)}']", count: 0
  end

  test "the split dialog shows the payment and two amount rows" do
    get new_tricount_payment_split_url(@payment)

    assert_response :success
    assert_select "form[action='#{tricount_payment_split_path(@payment)}'][data-controller~='split-transaction']" do
      assert_select "input[name='split[splits][0][amount]']"
      assert_select "input[name='split[splits][1][amount]']"
    end
    assert_select "h2", text: "Dinner (you paid)"
  end

  test "a split payment's part opens the dialog prefilled with the parts" do
    @tricount_account.split_payment!("e1", [ "70.00", "30.00" ])
    part = @account.entries.find_by!(external_id: "e1:paid:2")

    get transaction_url(part)
    assert_select "a[href='#{edit_tricount_payment_split_path(part)}']", text: I18n.t("splits.child.edit_split")
    assert_select "a[href='#{new_tricount_payment_split_path(part)}']", count: 0

    get edit_tricount_payment_split_url(part)
    assert_select "input[name='split[splits][0][amount]'][value='70.00']"
    assert_select "input[name='split[splits][1][amount]'][value='30.00']"
  end

  test "splitting a payment writes a row per part" do
    patch tricount_payment_split_url(@payment), params: split_params("70.00", "30.00")

    assert_redirected_to account_path(@account)
    assert_equal I18n.t("tricount_items.payment_split.saved"), flash[:notice]
    assert_equal [ "e1:paid:1", "e1:paid:2" ], @account.entries.where("external_id LIKE 'e1:paid%'").order(:external_id).pluck(:external_id)
  end

  test "a split that doesn't add up is refused with the total" do
    patch tricount_payment_split_url(@payment), params: split_params("70.00", "20.00")

    assert_equal I18n.t("tricount_items.payment_split.invalid", total: Money.new(100, "EUR").format), flash[:alert]
    assert_equal({}, @tricount_account.reload.paid_splits)
  end

  test "a part's row can undo the split" do
    @tricount_account.split_payment!("e1", [ "70.00", "30.00" ])
    part = @account.entries.find_by!(external_id: "e1:paid:2")

    delete tricount_payment_split_url(part)

    assert_redirected_to account_path(@account)
    assert_equal [ "e1:paid" ], @account.entries.where("external_id LIKE 'e1:paid%'").pluck(:external_id)
  end

  # Someone the account is only shared with, read-only, can't divide it.
  test "a user who can only read the account can't split its payments" do
    @account.update!(owner: users(:family_member))
    @account.account_shares.destroy_all
    @account.account_shares.create!(user: users(:family_admin), permission: "read_only")

    patch tricount_payment_split_url(@payment), params: split_params("70.00", "30.00")

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_equal({}, @tricount_account.reload.paid_splits)

    get new_tricount_payment_split_url(@payment)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]

    get transaction_url(@payment)
    assert_select "a[href='#{new_tricount_payment_split_path(@payment)}']", count: 0
  end

  test "a row that isn't a Tricount payment is not found" do
    share = @account.entries.find_by!(external_id: "e1:share")

    patch tricount_payment_split_url(share), params: split_params("10.00", "15.00")

    assert_response :not_found
  end

  private

    # The split dialog's rows, as split[splits][<index>][amount].
    def split_params(*amounts)
      { split: { splits: amounts.each_with_index.to_h { |amount, index| [ index.to_s, { amount: amount } ] } } }
    end
end
