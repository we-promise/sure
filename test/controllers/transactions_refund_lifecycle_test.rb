require "test_helper"

class TransactionsRefundLifecycleTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @credit = create_transaction(account: accounts(:credit_card), amount: -100, kind: "cc_payment")
  end

  test "generic updates cannot bypass refund classification and undo metadata" do
    patch transaction_path(@credit), params: {
      entry: { entryable_attributes: { id: @credit.entryable_id, kind: "refund" } }
    }

    assert_redirected_to transaction_path(@credit)
    assert_equal I18n.t("activerecord.errors.messages.invalid_refund"), flash[:alert]
    assert @credit.transaction.reload.cc_payment?
  end

  test "generic creation cannot classify a refund" do
    assert_no_difference "Entry.count" do
      post transactions_path, params: { entry: {
        account_id: accounts(:depository).id, name: "Return", amount: 100,
        nature: "inflow", date: Date.current, currency: "USD", entryable_type: "Transaction",
        entryable_attributes: { kind: "refund" }
      } }
    end

    assert_redirected_to transactions_path
    assert_equal I18n.t("activerecord.errors.messages.invalid_refund"), flash[:alert]
  end

  test "generic updates cannot clear refunds" do
    @credit.transaction.mark_as_refund!

    patch transaction_path(@credit), params: {
      entry: { entryable_attributes: { id: @credit.entryable_id, kind: "standard" } }
    }

    assert_redirected_to transaction_path(@credit)
    assert_equal I18n.t("activerecord.errors.messages.invalid_refund"), flash[:alert]
    assert @credit.transaction.reload.refund?
    @credit.transaction.clear_refund!
    assert @credit.transaction.reload.cc_payment?
  end

  test "generic updates can edit a refund without changing its kind" do
    @credit.transaction.mark_as_refund!

    patch transaction_path(@credit), params: {
      entry: { name: "Corrected name", entryable_attributes: { id: @credit.entryable_id, kind: "refund" } }
    }

    assert_response :redirect
    assert_equal "Corrected name", @credit.reload.name
    assert @credit.transaction.refund?
  end

  test "a supplied blank kind cannot bypass refund undo" do
    @credit.transaction.mark_as_refund!

    [ "", nil ].each do |kind|
      patch transaction_path(@credit), params: {
        entry: { entryable_attributes: { id: @credit.entryable_id, kind: kind } }
      }

      assert_redirected_to transaction_path(@credit)
      assert_equal I18n.t("activerecord.errors.messages.invalid_refund"), flash[:alert]
      assert @credit.transaction.reload.refund?
    end
  end
end
