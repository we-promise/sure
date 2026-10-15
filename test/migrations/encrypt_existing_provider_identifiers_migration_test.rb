# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261015220100_encrypt_existing_provider_identifiers")

class EncryptExistingProviderIdentifiersMigrationTest < ActiveSupport::TestCase
  setup do
    skip "Encryption not configured" unless EnableBankingAccount.encryption_ready?

    family = families(:dylan_family)
    @eb_item = EnableBankingItem.create!(family: family, name: "EB", country_code: "FI", application_id: "app", client_certificate: "cert")
    @eb_account = EnableBankingAccount.create!(enable_banking_item: @eb_item, name: "Checking", uid: "uid_migration", currency: "EUR")
    @akahu_account = AkahuAccount.create!(
      akahu_item: AkahuItem.create!(family: family, name: "Akahu", app_token: "app", user_token: "user"),
      name: "Everyday", account_id: "acc_encrypt_migration", currency: "NZD"
    )
    @lunchflow_account = lunchflow_items(:one).lunchflow_accounts.create!(name: "Brokerage", currency: "GBP", account_id: "encrypt-migration")
  end

  test "encrypts plaintext left by earlier syncs so the next read does not raise" do
    write_raw(EnableBankingAccount, @eb_account.id, "iban", "FI2112345600000785") # pipelock:ignore IBAN
    write_raw(EnableBankingItem, @eb_item.id, "last_psu_ip", "203.0.113.9")
    write_raw(AkahuAccount, @akahu_account.id, "formatted_account", "12-3456-7654321-00")
    write_raw(LunchflowAccount, @lunchflow_account.id, "raw_holdings_payload", [ { "symbol" => "HOLDPROBE" } ].to_json, cast: "::jsonb")

    assert_raises(ActiveRecord::Encryption::Errors::Decryption) { @eb_item.reload.last_psu_ip }

    run_migration

    assert_equal "FI2112345600000785", @eb_account.reload.iban # pipelock:ignore IBAN
    assert_equal "203.0.113.9", @eb_item.reload.last_psu_ip
    assert_equal "12-3456-7654321-00", @akahu_account.reload.formatted_account
    assert_equal [ { "symbol" => "HOLDPROBE" } ], @lunchflow_account.reload.raw_holdings_payload
    refute_includes @eb_account.read_attribute_before_type_cast(:iban).to_s, "785"
    refute_includes @lunchflow_account.read_attribute_before_type_cast(:raw_holdings_payload).to_s, "HOLDPROBE"
  end

  test "leaves values that are already encrypted unchanged" do
    @eb_account.update!(iban: "FI2112345600000785") # pipelock:ignore IBAN
    ciphertext = @eb_account.reload.read_attribute_before_type_cast(:iban)

    run_migration

    assert_equal ciphertext, @eb_account.reload.read_attribute_before_type_cast(:iban)
    assert_equal "FI2112345600000785", @eb_account.iban # pipelock:ignore IBAN
  end

  private

    def write_raw(model, id, column, value, cast: "")
      ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
        "UPDATE #{model.quoted_table_name} SET #{column} = ?#{cast} WHERE id = ?", value, id
      ]))
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        EncryptExistingProviderIdentifiers.new.migrate(:up)
      end
    end
end
