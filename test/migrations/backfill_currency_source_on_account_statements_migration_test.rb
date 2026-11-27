require "test_helper"
require Rails.root.join("db/migrate/20261126100100_backfill_currency_source_on_account_statements")

class BackfillCurrencySourceOnAccountStatementsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    connection = ActiveRecord::Base.connection
    connection.change_column_null :account_statements, :currency, true
    connection.change_column_null :account_statements, :currency_source, true
  end

  test "a linked statement takes its account's currency unless it was picked by hand" do
    same = statement(account: @account, currency: @account.currency)
    blank = statement(account: @account, currency: nil)
    other = statement(account: @account, currency: "GBP")

    run_migration

    assert_equal [ @account.currency, "account" ], currency_of(same)
    assert_equal [ @account.currency, "account" ], currency_of(blank)
    assert_equal [ "GBP", "user" ], currency_of(other)
  end

  test "an unlinked statement holds the family default unless the document named another" do
    same = statement(account: nil, currency: @family.currency)
    blank = statement(account: nil, currency: nil)
    other = statement(account: nil, currency: "EUR")

    run_migration

    assert_equal [ @family.currency, "family_default" ], currency_of(same)
    assert_equal [ @family.currency, "family_default" ], currency_of(blank)
    assert_equal [ "EUR", "document" ], currency_of(other)
  end

  private
    def run_migration
      ActiveRecord::Migration.suppress_messages { BackfillCurrencySourceOnAccountStatements.new.up }
    end

    def statement(account:, currency:)
      AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(filename: "#{SecureRandom.hex(4)}.csv", content_type: "text/csv", content: SecureRandom.hex(8))
      ).tap { |record| record.update_columns(currency: currency, currency_source: nil) }
    end

    def currency_of(record)
      record.reload.values_at(:currency, :currency_source)
    end
end
