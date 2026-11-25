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

  test "the accounts step shows suggested balances with a dot in a comma-decimal locale" do
    @user.update!(locale: "de")
    upload_exports

    get import_configuration_url(@import)

    assert_response :success
    assert_select "input[name$='[current_balance]']" do |inputs|
      inputs.each { |input| assert_no_match(/,/, input["value"].to_s) }
    end
  end

  test "the accounts step shows a balance in its target's currency with its decimals" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    target = @user.family.accounts.create!(name: "Yen", balance: 0, currency: "JPY", accountable: Depository.new)
    checking.update!(mappable: target, choices: { current_balance: "123.456" })

    get import_configuration_url(@import)

    assert_response :success
    field = "input[name='accounts[#{checking.id}][current_balance]']"
    assert_select "#{field}[value='123.456']"
    assert_select "[data-controller='money-field']:has(#{field}) [data-money-field-target='symbol']", text: "¥"
  end

  test "a balance saved for a whole-number target keeps its decimals as a minimum" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    target = @user.family.accounts.create!(name: "Yen", balance: 0, currency: "JPY", accountable: Depository.new)
    checking.update!(mappable: target, choices: { current_balance: "123.4" })

    get import_configuration_url(@import)

    # The saved decimal is a minimum, not a fixed precision, so a switch to a
    # USD account still takes cents.
    field = "input[name='accounts[#{checking.id}][current_balance]']"
    assert_select "#{field}[value='123.4']"
    assert_select "[data-controller='money-field'][data-money-field-min-precision-value='1']:has(#{field})"
    assert_select "[data-controller='money-field'][data-money-field-precision-value]:has(#{field})", 0
  end

  test "a whole balance for a whole-number target follows that currency" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    target = @user.family.accounts.create!(name: "Yen", balance: 0, currency: "JPY", accountable: Depository.new)
    checking.update!(mappable: target, choices: { current_balance: "1500" })

    get import_configuration_url(@import)

    assert_select "input[name='accounts[#{checking.id}][current_balance]'][value='1500']"
  end

  test "an account the user can't access can't be a target" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    other_family_account = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)

    patch import_configuration_url(@import), params: { accounts: { checking.id => { type: "Depository", target_id: other_family_account.id, include: "1" } } }

    assert_response :not_found
    assert_nil checking.reload.target
  end

  test "a read-only shared account can't be a target, or be published into" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    read_only = accounts(:credit_card)
    sign_in users(:family_member)

    patch import_configuration_url(@import), params: { accounts: { checking.id => { type: "CreditCard", target_id: read_only.id, include: "1" } } }
    assert_response :not_found

    checking.update!(mappable: read_only)
    assert_no_enqueued_jobs(only: ImportJob) do
      post publish_import_url(@import)
    end
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "saving with no accounts submitted changes nothing" do
    upload_exports
    checking = @import.account_mappings.find_by!(key: "Checking")
    checking.update!(choices: { "name" => "Everyday", "transactions" => false })

    patch import_configuration_url(@import), params: { other: "1" }

    assert_redirected_to import_url(@import)
    assert_equal [ "Everyday", false ], checking.reload.choices.values_at("name", "transactions")
  end

  test "the confirm step goes back to the accounts step" do
    upload_exports
    get import_url(@import)

    assert_select "header > a[href='#{import_configuration_path(@import)}']"
  end

  test "two Monarch accounts can't go into the same account" do
    upload_exports
    checking, card = %w[Checking Card].map { |name| @import.account_mappings.find_by!(key: name) }
    target = accounts(:depository)

    patch import_configuration_url(@import), params: { accounts: {
      checking.id => { type: "Depository", target_id: target.id, include: "1" },
      card.id => { type: "CreditCard", target_id: target.id, include: "1" }
    } }

    assert_redirected_to import_configuration_url(@import)
    assert_match "already the destination", flash[:alert]
    assert_nil checking.reload.target
  end

  test "an import whose data committed before failing can't change its files or choices" do
    upload_exports
    Family.any_instance.stubs(:sync_later).raises(StandardError, "queue down")
    @import.publish
    assert @import.reload.failed?
    checking = @import.account_mappings.find_by!(key: "Checking")

    patch import_configuration_url(@import), params: { accounts: { checking.id => { type: "Depository", include: "0" } } }
    assert_redirected_to import_url(@import)
    assert_equal I18n.t("imports.configuration_locked"), flash[:alert]
    assert checking.reload.include

    patch import_upload_url(@import), params: { import: { balances_file: csv_upload("monarch_balances.csv") } }
    assert_redirected_to import_url(@import)
    assert_equal 3, @import.account_mappings.count
  end

  test "confirm shows the summary and publishes" do
    upload_exports
    get import_url(@import)
    assert_response :success

    assert_enqueued_with(job: ImportJob) do
      post publish_import_url(@import)
    end
  end

  test "trying again after a destination stopped qualifying goes back to the accounts step" do
    upload_exports
    target = accounts(:depository)
    @import.account_mappings.find_by!(key: "Checking").update!(mappable: target)
    security = Security.create!(ticker: "MONA", name: "Monarch Test")
    target.entries.create!(date: Date.new(2024, 1, 4), amount: 10, currency: "USD", name: "Buy",
      entryable: Trade.new(security: security, qty: 1, price: 10, currency: "USD"))
    @import.publish
    assert @import.reload.failed?

    assert_no_enqueued_jobs(only: ImportJob) do
      post publish_import_url(@import)
    end
    assert_redirected_to import_url(@import)
    follow_redirect!
    assert_redirected_to import_configuration_url(@import)
    assert_match target.name, flash[:alert]
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
