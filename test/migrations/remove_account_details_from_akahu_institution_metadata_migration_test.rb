# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261015220000_remove_account_details_from_akahu_institution_metadata")

class RemoveAccountDetailsFromAkahuInstitutionMetadataMigrationTest < ActiveSupport::TestCase
  setup do
    item = AkahuItem.create!(family: families(:dylan_family), name: "Akahu", app_token: "app", user_token: "user")
    @account = AkahuAccount.create!(akahu_item: item, name: "Everyday", account_id: "acc_migration", currency: "NZD")
  end

  test "strips the account number and holder but keeps the institution details" do
    @account.update_column(:institution_metadata, {
      "id" => "conn_1", "name" => "Test Bank", "logo" => "logo.png",
      "account_number" => "12-3456-7654321-00", "holder" => "Test Person"
    })

    run_migration

    assert_equal({ "id" => "conn_1", "name" => "Test Bank", "logo" => "logo.png" }, @account.reload.institution_metadata)
  end

  test "strips either key when only one of them is present" do
    other = AkahuAccount.create!(akahu_item: @account.akahu_item, name: "Savings", account_id: "acc_migration_2", currency: "NZD")
    @account.update_column(:institution_metadata, { "name" => "Test Bank", "account_number" => "12-3456-7654321-00" })
    other.update_column(:institution_metadata, { "name" => "Test Bank", "holder" => "Test Person" })

    run_migration

    assert_equal({ "name" => "Test Bank" }, @account.reload.institution_metadata)
    assert_equal({ "name" => "Test Bank" }, other.reload.institution_metadata)
  end

  test "leaves metadata without those keys alone" do
    @account.update_column(:institution_metadata, { "name" => "Test Bank" })

    run_migration

    assert_equal({ "name" => "Test Bank" }, @account.reload.institution_metadata)
  end

  private

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RemoveAccountDetailsFromAkahuInstitutionMetadata.new.migrate(:up)
      end
    end
end
