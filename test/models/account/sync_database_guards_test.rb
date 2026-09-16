require "test_helper"

class Account::SyncDatabaseGuardsTest < ActiveSupport::TestCase
  test "every immutable account execution guard is installed and enabled in the database" do
    guards = ApplicationRecord.connection.select_rows(<<~SQL)
      SELECT c.relname, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid)
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema() AND NOT t.tgisinternal
        AND t.tgname IN ('account_sync_inputs_immutable', 'account_sync_preparations_immutable', 'sync_account_seal')
    SQL
    expected = { "account_sync_inputs" => "account_sync_inputs_immutable",
      "account_sync_preparations" => "account_sync_preparations_immutable", "syncs" => "sync_account_seal" }
    assert_equal expected, guards.to_h { |table, name, _enabled, _definition| [ table, name ] },
      "Account sync acceptance requires migration-installed PostgreSQL guards; schema.rb does not restore triggers"
    guards.each do |table, _name, enabled, definition|
      assert_includes %w[O A], enabled, "#{table} guard must execute for ordinary application writes"
      assert_includes definition, "BEFORE"
      assert_includes definition, table == "syncs" ? "guard_account_sync_seal()" : "guard_account_sync_evidence()"
    end
  end
end
