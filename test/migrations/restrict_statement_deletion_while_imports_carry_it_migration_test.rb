# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261124120000_restrict_statement_deletion_while_imports_carry_it")

class RestrictStatementDeletionWhileImportsCarryItMigrationTest < ActiveSupport::TestCase
  # Each test starts from the foreign key an installation has before the
  # migration. DDL is transactional in Postgres, so the change is rolled back
  # with the rest of the test.
  setup do
    migration.down
    @statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family),
      account: accounts(:depository),
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    @import = TransactionImport.create!(family: @statement.family, account: @statement.account, account_statement: @statement)
  end

  test "the database refuses to delete a statement an import carries" do
    migration.up

    # A savepoint, so the refused DELETE leaves the test's transaction usable.
    assert_raises(ActiveRecord::InvalidForeignKey) do
      AccountStatement.transaction(requires_new: true) { AccountStatement.where(id: @statement.id).delete_all }
    end
    assert_equal @statement.id, @import.reload.account_statement_id
  end

  test "rolling back nullifies the import's statement again" do
    migration.up
    migration.down

    AccountStatement.where(id: @statement.id).delete_all

    assert_nil @import.reload.account_statement_id
  end

  test "a statement without imports can still be deleted" do
    migration.up
    @import.destroy!

    assert_difference -> { AccountStatement.count }, -1 do
      @statement.destroy!
    end
  end

  private
    def migration
      @migration ||= RestrictStatementDeletionWhileImportsCarryIt.new.tap { |m| m.verbose = false }
    end
end
