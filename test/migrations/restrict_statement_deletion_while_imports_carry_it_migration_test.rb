# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261124120000_restrict_statement_deletion_while_imports_carry_it")
require Rails.root.join("db/migrate/20261124120100_validate_imports_account_statement_foreign_key")

class RestrictStatementDeletionWhileImportsCarryItMigrationTest < ActiveSupport::TestCase
  # Each test starts from the foreign key an installation has before both
  # migrations. DDL is transactional in Postgres, so the change is rolled back
  # with the rest of the test.
  setup do
    validation.down
    restriction.down
    @statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family),
      account: accounts(:depository),
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    @import = TransactionImport.create!(family: @statement.family, account: @statement.account, account_statement: @statement)
  end

  test "the key added not valid already refuses to delete a statement an import carries" do
    restriction.up

    assert_not foreign_key_validated?
    assert_statement_deletion_refused
  end

  test "the database refuses to delete a statement an import carries once the key is validated" do
    restriction.up
    validation.up

    assert foreign_key_validated?
    assert_statement_deletion_refused
  end

  test "rolling back the validation leaves the key not valid and still enforced" do
    restriction.up
    validation.up
    validation.down

    assert_not foreign_key_validated?
    assert_statement_deletion_refused
  end

  test "rolling back both nullifies the import's statement again" do
    restriction.up
    validation.up
    validation.down
    restriction.down

    assert foreign_key_validated?
    AccountStatement.where(id: @statement.id).delete_all

    assert_nil @import.reload.account_statement_id
  end

  test "a statement without imports can still be deleted" do
    restriction.up
    validation.up
    @import.destroy!

    assert_difference -> { AccountStatement.count }, -1 do
      @statement.destroy!
    end
  end

  private
    def restriction
      @restriction ||= RestrictStatementDeletionWhileImportsCarryIt.new.tap { |m| m.verbose = false }
    end

    def validation
      @validation ||= ValidateImportsAccountStatementForeignKey.new.tap { |m| m.verbose = false }
    end

    def foreign_key_validated?
      ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT convalidated FROM pg_constraint
        WHERE contype = 'f' AND conrelid = 'imports'::regclass AND confrelid = 'account_statements'::regclass
      SQL
    end

    # A savepoint, so the refused DELETE leaves the test's transaction usable.
    def assert_statement_deletion_refused
      assert_raises(ActiveRecord::InvalidForeignKey) do
        AccountStatement.transaction(requires_new: true) { AccountStatement.where(id: @statement.id).delete_all }
      end
      assert_equal @statement.id, @import.reload.account_statement_id
    end
end
