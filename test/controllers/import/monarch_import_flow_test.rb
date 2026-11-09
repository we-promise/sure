require "test_helper"

class Import::MonarchImportFlowTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = @user.family.imports.create!(type: "MonarchImport")
  end

  test "upload shows both file fields" do
    get import_upload_url(@import)

    assert_response :success
    assert_select "input[type=file][name='import[balances_file]']"
    assert_select "input[type=file][name='import[transactions_file]']"
    assert_select "a[href='https://app.monarch.com/settings/data'][target=_blank]"
  end

  test "uploading the exports goes to the accounts step" do
    upload_exports

    assert_redirected_to import_configuration_url(@import)
    assert_equal %w[Card Checking Old\ Savings], @import.account_mappings.order(:key).pluck(:key)
  end

  test "uploading without the balances export is rejected" do
    patch import_upload_url(@import), params: { import: { transactions_file: csv_upload("monarch_transactions.csv") } }

    assert_response :unprocessable_entity
    assert_not @import.reload.uploaded?
  end

  test "uploading the wrong file explains what's missing" do
    patch import_upload_url(@import), params: { import: { balances_file: csv_upload("monarch_transactions.csv") } }

    assert_response :unprocessable_entity
    assert_match "missing the columns Balance", response.body
  end

  test "the accounts step lists each account and saves the choices" do
    upload_exports
    get import_configuration_url(@import)
    assert_response :success
    assert_select "table tbody tr", 3

    checking = @import.account_mappings.find_by!(key: "Checking")
    target = accounts(:depository)
    patch import_configuration_url(@import), params: { accounts: {
      checking.id => { name: "Everyday", type: "Depository", target_id: target.id, include: "1", closed: "0", transactions: "0", current_balance: "250" }
    } }

    assert_redirected_to import_url(@import)
    checking.reload
    assert_equal [ target, false, "250", "Everyday" ], [ checking.target, checking.to_converter_choice.transactions, checking.current_balance, checking.account_name ]
  end

  test "an account the user can't access can't be a target" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    other_family_account = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)

    patch import_configuration_url(@import), params: { accounts: { checking.id => { type: "Depository", target_id: other_family_account.id, include: "1" } } }

    assert_response :not_found
    assert_nil checking.reload.target
  end

  test "confirm shows the summary and publishes" do
    upload_exports
    get import_url(@import)
    assert_response :success

    assert_enqueued_with(job: ImportJob) do
      post publish_import_url(@import)
    end
  end

  private
    def csv_upload(name)
      fixture_file_upload("imports/#{name}", "text/csv")
    end

    def upload_exports
      patch import_upload_url(@import), params: { import: {
        balances_file: csv_upload("monarch_balances.csv"),
        transactions_file: csv_upload("monarch_transactions.csv")
      } }
    end
end
