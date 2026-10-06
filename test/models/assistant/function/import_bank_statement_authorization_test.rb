require "test_helper"

class Assistant::Function::ImportBankStatementAuthorizationTest < ActiveSupport::TestCase
  setup do
    @member = users(:family_member)
    @family = @member.family
    @function = Assistant::Function::ImportBankStatement.new(@member)
    @pdf_import = imports(:pdf_processed)
    @private_account = @family.accounts.create!(
      owner: users(:family_admin),
      name: "Private Import Account",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )
  end

  test "only advertises writable depository accounts" do
    result = @function.call("pdf_import_id" => @pdf_import.id)

    assert_equal "account_required", result[:error]
    ids = result[:available_accounts].pluck(:id)
    assert_includes ids, accounts(:depository).id
    assert_not_includes ids, @private_account.id
  end

  test "rejects an inaccessible account before extraction" do
    result = @function.call("pdf_import_id" => @pdf_import.id, "account_id" => @private_account.id)

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "rechecks account permission after extraction before creating the import" do
    provider = mock
    provider.expects(:extract_bank_statement).returns(
      stub(success?: true, data: { transactions: [ { date: Date.current.iso8601, amount: 10, name: "Test" } ], period: nil, account_holder: nil })
    )
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    Account::MutationAccess.expects(:lock!).raises(Account::MutationAccess::Denied)

    assert_no_difference "Import.count" do
      result = @function.call("pdf_import_id" => @pdf_import.id, "account_id" => accounts(:depository).id)
      assert_equal "account_not_found", result[:error]
    end
  end

  test "rejects users who cannot manage bank statements" do
    AccountStatement.stubs(:statement_manager?).with(@member).returns(false)

    result = @function.call("pdf_import_id" => @pdf_import.id)

    assert_equal false, result[:success]
    assert_equal "forbidden", result[:error]
  end
end
