require "test_helper"

class RefundsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @purchase = create_transaction(amount: 1000, category: categories(:one))
    @refund = create_transaction(amount: -800)
  end

  test "marks an incoming transaction as a linked partial refund" do
    post transaction_refund_path(@refund), params: { refund: { purchase_entry_id: @purchase.id } }

    assert_redirected_to transaction_path(@refund)
    assert @refund.transaction.reload.refund?
    assert_equal @purchase.transaction, @refund.transaction.refund_of
    assert_equal(-800, @refund.reload.amount)
  end

  test "supports an unlinked refund and undo" do
    post transaction_refund_path(@refund), params: { refund: { purchase_entry_id: "" } }
    assert @refund.transaction.reload.refund?
    delete transaction_refund_path(@refund)
    assert @refund.transaction.reload.standard?
  end

  test "preview gate prevents classification" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    post transaction_refund_path(@refund), params: { refund: { purchase_entry_id: @purchase.id } }
    assert_redirected_to root_path
    assert @refund.transaction.reload.standard?
  end

  test "rejects inaccessible purchases" do
    account = families(:empty).accounts.create!(name: "Private", balance: 1000, currency: "USD", accountable: Depository.new)
    purchase = create_transaction(account: account)
    post transaction_refund_path(@refund), params: { refund: { purchase_entry_id: purchase.id } }
    assert_response :not_found
    assert @refund.transaction.reload.standard?
  end

  test "rejects an outflow without modifying it" do
    post transaction_refund_path(@purchase), params: { refund: { purchase_entry_id: "" } }
    assert_redirected_to transaction_path(@purchase)
    assert @purchase.transaction.reload.standard?
  end

  test "read only account shares cannot mark refunds" do
    sign_in member = users(:family_member)
    member.update!(preferences: member.preferences.merge("preview_features_enabled" => true))
    credit = create_transaction(account: accounts(:credit_card), amount: -800)
    post transaction_refund_path(credit), params: { refund: { purchase_entry_id: "" } }
    assert_redirected_to transactions_path
    assert credit.transaction.reload.standard?
  end

  test "editing a linked refund preserves its current purchase selection" do
    @refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    get new_transaction_refund_path(@refund)
    assert_response :success
    assert_select "option[selected][value=?]", @purchase.id
    assert_select "form[data-turbo-frame='_top']"
  end

  test "refund overview submits inflow direction when editing the displayed amount" do
    @refund.transaction.mark_as_refund!
    get transaction_path(@refund)
    assert_select "input[type='hidden'][name='entry[nature]'][value='inflow']"
    patch transaction_path(@refund), params: { entry: { name: "Return credit", amount: "800", nature: "inflow" } }
    assert_equal "Return credit", @refund.reload.name
    assert_equal(-800, @refund.amount)
    assert @refund.transaction.reload.refund?
  end

  test "refund cannot be turned into a recurring income series" do
    @refund.transaction.mark_as_refund!
    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(@refund.transaction)
    end
    assert_redirected_to transactions_path
  end

  test "renders purchase selection and net cost details" do
    get new_transaction_refund_path(@refund)
    assert_response :success
    assert_select "select[name='refund[purchase_entry_id]']"
    @refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    get transaction_path(@purchase)
    assert_response :success
    assert_select "[data-testid='purchase-net-cost']", text: /200/
  end
end
