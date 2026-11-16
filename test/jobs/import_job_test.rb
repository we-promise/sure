require "test_helper"

class ImportJobTest < ActiveJob::TestCase
  test "import is published" do
    import = imports(:transaction)
    import.expects(:publish).once

    ImportJob.perform_now(import)
  end

  test "publishing later carries the initiating user into the job" do
    import = imports(:transaction)
    user = users(:family_member)
    Current.stubs(:user).returns(user)
    import.stubs(:publishable?).returns(true)

    assert_enqueued_with job: ImportJob, args: [ import, { initiating_user: user } ] do
      import.publish_later
    end
  end

  test "YNAB accounts belong to the importer and follow shared family defaults" do
    user = users(:family_member)
    user.update!(role: "super_admin")
    user.family.update!(default_account_sharing: "shared")
    import = new_ynab_import(user.family)
    Current.stubs(:user).returns(nil)

    ImportJob.perform_now(import.reload, initiating_user: user)

    assert_predicate import, :complete?, import.error
    account = import.accounts.sole
    assert_equal user, account.owner
    share = account.account_shares.find_by!(user: users(:family_admin))
    assert_equal "read_write", share.permission
    assert share.include_in_finances
  end

  test "YNAB accounts stay private when the family default is private" do
    user = users(:family_member)
    user.family.update!(default_account_sharing: "private")
    import = new_ynab_import(user.family)
    Current.stubs(:user).returns(nil)

    ImportJob.perform_now(import.reload, initiating_user: user)

    assert_predicate import, :complete?, import.error
    account = import.accounts.sole
    assert_equal user, account.owner
    assert_empty account.account_shares
  end

  test "YNAB import does not change an existing mapped account's access" do
    user = users(:family_member)
    user.family.update!(default_account_sharing: "shared")
    account = accounts(:depository)
    owner = account.owner
    shares = account.account_shares.order(:id).pluck(:user_id, :permission, :include_in_finances)
    import = new_ynab_import(user.family)
    import.mappings.accounts.sole.update!(mappable: account)
    Current.stubs(:user).returns(nil)

    ImportJob.perform_now(import.reload, initiating_user: user)

    assert_predicate import, :complete?, import.error
    assert_equal owner, account.reload.owner
    assert_equal shares, account.account_shares.order(:id).pluck(:user_id, :permission, :include_in_finances)
  end

  test "an initiating user from another family cannot own imported accounts" do
    import = new_ynab_import(families(:dylan_family))
    Current.stubs(:user).returns(nil)

    assert_no_difference "Account.count" do
      ImportJob.perform_now(import.reload, initiating_user: users(:empty))
    end

    assert_predicate import, :failed?
    assert_empty import.accounts
  end

  private
    def new_ynab_import(family)
      import = family.imports.create!(type: "YnabImport", raw_file_str: <<~CSV)
        Account,Date,Payee,Outflow,Inflow
        YNAB Checking,01/01/2024,Store,10,0
      CSV
      import.generate_rows_from_csv
      import.mappings.create!(type: "Import::AccountMapping", key: "YNAB Checking", create_when_empty: true)
      import
    end
end
