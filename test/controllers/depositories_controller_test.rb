require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "create falls back to the stored return_to when no form param is present" do
    get new_account_path(return_to: transactions_path) # StoreLocation captures it into the session

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "Return To Checking", currency: "USD", balance: 100, accountable_type: "Depository" }
      }
    end

    assert_redirected_to transactions_path
  end

  test "create prefers the form return_to over the session value" do
    get new_account_path(return_to: transactions_path) # session return_to

    post depositories_path, params: {
      account: { name: "Form RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: budgets_path }
    }

    assert_redirected_to budgets_path
  end

  test "create ignores an external return_to (open-redirect guard)" do
    post depositories_path, params: {
      account: { name: "Evil RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: "https://evil.example/phish" }
    }

    created = Account.order(:created_at).last
    assert_redirected_to account_path(created) # not the external URL
  end

  test "create persists a manually entered iban" do
    post depositories_path, params: {
      account: { name: "IBAN Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "de89 3704 0044 0532 0130 00" }
    }

    created = Account.order(:created_at).last
    assert_equal "DE89370400440532013000", created.iban # pipelock:ignore IBAN
  end

  test "create re-renders the form instead of a 500 when the iban is already used in the family" do
    @account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    assert_no_difference -> { Account.count } do
      post depositories_path, params: {
        account: { name: "Duplicate IBAN Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "DE89370400440532013000" } # pipelock:ignore IBAN
      }
    end

    assert_response :unprocessable_entity
  end

  test "create re-renders the form instead of a 500 on a raw unique-index race" do
    # Simulates two concurrent requests both passing the Rails uniqueness
    # validation before either commits -- the second one hits the raw DB
    # constraint instead, surfacing as RecordNotUnique rather than the
    # RecordInvalid the previous test covers.
    Account.any_instance.stubs(:save!).raises(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    assert_no_difference -> { Account.count } do
      post depositories_path, params: {
        account: { name: "Race Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "DE89370400440532013000" } # pipelock:ignore IBAN
      }
    end

    assert_response :unprocessable_entity
  end

  test "update re-renders the form instead of a 500 on a raw unique-index race" do
    linked_account = accounts(:connected)
    Account.any_instance.stubs(:update).raises(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    patch depository_path(linked_account), params: {
      account: { iban: "DE89370400440532013000" } # pipelock:ignore IBAN
    }

    assert_response :unprocessable_entity
  end

  test "update rolls back a balance change when the iban update fails in the same request" do
    linked_account = accounts(:connected)
    other_account = accounts(:depository)
    other_account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN
    original_balance = linked_account.balance

    patch depository_path(linked_account), params: {
      account: { balance: original_balance + 100, iban: "DE89370400440532013000" } # pipelock:ignore IBAN
    }

    assert_response :unprocessable_entity
    assert_equal original_balance, linked_account.reload.balance,
      "the balance change must not persist when the same request's iban update fails"
  end

  test "update persists a manually entered iban through the shared update action" do
    linked_account = accounts(:connected)

    patch depository_path(linked_account), params: {
      account: { iban: "AT611904300234573201" } # pipelock:ignore IBAN
    }

    assert_equal "AT611904300234573201", linked_account.reload.iban # pipelock:ignore IBAN
  end

  test "update persists enable_category_matcher through the shared update action" do
    linked_account = accounts(:connected)
    assert linked_account.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "0" }
    }

    refute linked_account.reload.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "1" }
    }

    assert linked_account.reload.enable_category_matcher?
  end

  test "edit form renders category matcher toggle only for accounts that support it" do
    get edit_account_url(accounts(:connected))
    assert_response :success
    assert_select "input[type=checkbox][name='account[enable_category_matcher]']", 1

    get edit_account_url(accounts(:depository))
    assert_response :success
    assert_select "input[name='account[enable_category_matcher]']", 0
  end
end
