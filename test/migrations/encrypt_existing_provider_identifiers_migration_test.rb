# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261015220100_encrypt_existing_provider_identifiers")

class EncryptExistingProviderIdentifiersMigrationTest < ActiveSupport::TestCase
  setup do
    skip "Encryption not configured" unless EnableBankingItem.encryption_ready?

    family = families(:dylan_family)
    @eb_item = EnableBankingItem.create!(family: family, name: "EB", country_code: "FI", application_id: "app", client_certificate: "cert")
    @akahu_account = AkahuAccount.create!(
      akahu_item: AkahuItem.create!(family: family, name: "Akahu", app_token: "app", user_token: "user"),
      name: "Everyday", account_id: "acc_encrypt_migration", currency: "NZD"
    )
    @lunchflow_account = lunchflow_items(:one).lunchflow_accounts.create!(name: "Brokerage", currency: "GBP", account_id: "encrypt-migration")
  end

  test "encrypts plaintext left by earlier syncs" do
    write_raw(EnableBankingItem, @eb_item.id, "last_psu_ip", "203.0.113.9")
    write_raw(AkahuAccount, @akahu_account.id, "formatted_account", "12-3456-7654321-00")
    write_raw(LunchflowAccount, @lunchflow_account.id, "raw_holdings_payload", [ { "symbol" => "HOLDPROBE" } ].to_json, cast: "::jsonb")

    # Still readable before the migration, so syncs keep working meanwhile
    assert_equal "203.0.113.9", @eb_item.reload.last_psu_ip
    assert_equal [ { "symbol" => "HOLDPROBE" } ], @lunchflow_account.reload.raw_holdings_payload

    run_migration

    assert_equal "203.0.113.9", @eb_item.reload.last_psu_ip
    assert_equal "12-3456-7654321-00", @akahu_account.reload.formatted_account
    assert_equal [ { "symbol" => "HOLDPROBE" } ], @lunchflow_account.reload.raw_holdings_payload
    refute_includes @eb_item.read_attribute_before_type_cast(:last_psu_ip).to_s, "203.0.113.9"
    refute_includes @akahu_account.read_attribute_before_type_cast(:formatted_account).to_s, "7654321"
    refute_includes @lunchflow_account.read_attribute_before_type_cast(:raw_holdings_payload).to_s, "HOLDPROBE"
  end

  test "leaves values that are already encrypted unchanged" do
    @akahu_account.update!(formatted_account: "12-3456-7654321-00")
    ciphertext = @akahu_account.reload.read_attribute_before_type_cast(:formatted_account)

    run_migration

    assert_equal ciphertext, @akahu_account.reload.read_attribute_before_type_cast(:formatted_account)
    assert_equal "12-3456-7654321-00", @akahu_account.formatted_account
  end

  test "leaves an already encrypted json payload unchanged" do
    @lunchflow_account.update!(raw_holdings_payload: [ { "symbol" => "HOLDPROBE" } ])
    ciphertext = stored_text(LunchflowAccount, @lunchflow_account.id, "raw_holdings_payload")

    run_migration

    assert_equal ciphertext, stored_text(LunchflowAccount, @lunchflow_account.id, "raw_holdings_payload")
    assert_equal [ { "symbol" => "HOLDPROBE" } ], @lunchflow_account.reload.raw_holdings_payload
  end

  test "does not overwrite a value written after it was read" do
    write_raw(EnableBankingItem, @eb_item.id, "last_psu_ip", "203.0.113.20")
    migration = EncryptExistingProviderIdentifiers.new
    migration.stubs(:each_stored_value).yields(@eb_item.id, "203.0.113.10")

    migration.send(:encrypt_plaintext, EnableBankingItem, "last_psu_ip")

    assert_equal "203.0.113.20", stored_text(EnableBankingItem, @eb_item.id, "last_psu_ip")
  end

  test "down writes the values back as plaintext" do
    @eb_item.update!(last_psu_ip: "203.0.113.30")
    @akahu_account.update!(formatted_account: "12-3456-7654321-00")
    @lunchflow_account.update!(raw_holdings_payload: [ { "symbol" => "HOLDPROBE" } ])

    run_migration(:down)

    assert_equal "203.0.113.30", stored_text(EnableBankingItem, @eb_item.id, "last_psu_ip")
    assert_equal "12-3456-7654321-00", stored_text(AkahuAccount, @akahu_account.id, "formatted_account")
    assert_equal [ { "symbol" => "HOLDPROBE" } ], JSON.parse(stored_text(LunchflowAccount, @lunchflow_account.id, "raw_holdings_payload"))
    assert_equal "203.0.113.30", @eb_item.reload.last_psu_ip
    assert_equal [ { "symbol" => "HOLDPROBE" } ], @lunchflow_account.reload.raw_holdings_payload
  end

  private

    def stored_text(model, id, column)
      ActiveRecord::Base.connection.select_value(
        model.unscoped.where(id: id).select(Arel.sql("#{column}::text")).to_sql
      )
    end

    def write_raw(model, id, column, value, cast: "")
      ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
        "UPDATE #{model.quoted_table_name} SET #{column} = ?#{cast} WHERE id = ?", value, id
      ]))
    end

    def run_migration(direction = :up)
      ActiveRecord::Migration.suppress_messages do
        EncryptExistingProviderIdentifiers.new.migrate(direction)
      end
    end
end
