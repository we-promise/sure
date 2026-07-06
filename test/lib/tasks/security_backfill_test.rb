# frozen_string_literal: true

require "test_helper"

class SecurityBackfillTest < ActiveSupport::TestCase
  # Follows the suite convention (see test/encryption_verification_test.rb):
  # runs only when explicit encryption keys are configured, e.g.
  #
  #   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=test \
  #   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=test \
  #   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=test \
  #   bin/rails test test/lib/tasks/security_backfill_test.rb
  setup do
    skip "Encryption not configured" unless LunchflowAccount.encryption_ready?
    Rails.application.load_tasks unless Rake::Task.task_defined?("security:backfill_encryption")
    Rake::Task["security:backfill_encryption"].reenable
  end

  # Lunchflow is a representative provider model, chosen arbitrarily: the bug
  # this guards against applies identically to every json/jsonb encrypts
  # column the task touches (the Plaid/SimpleFin/Enable Banking/... raw
  # payload columns), via the shared safe_read_field helper.
  test "backfill preserves jsonb payload structure and string fields" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Test", api_key: "seed")
    item.save!(validate: false)
    account = item.lunchflow_accounts.create!(
      name: "Backfill Test Account", currency: "GBP", account_id: "backfill-test-1")

    payload = [ { "id" => "tx-1", "amount" => -4.5, "currency" => "GBP", "date" => "2026-07-01" } ]

    # Simulate rows written before encryption was enabled: bypass the encrypted
    # setters and write plaintext values directly to the columns.
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_accounts SET raw_transactions_payload = ?::jsonb WHERE id = ?",
      payload.to_json, account.id ]))
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_items SET api_key = ? WHERE id = ?", "plaintext-key", item.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_kind_of Array, account.raw_transactions_payload,
      "jsonb payload must decrypt to its original structure, not the JSON text"
    assert_equal "tx-1", account.raw_transactions_payload.first["id"]
    assert_equal "plaintext-key", item.reload.api_key

    # The stored value is ciphertext, not plaintext jsonb
    at_rest = account.read_attribute_before_type_cast(:raw_transactions_payload).to_s
    refute_includes at_rest, "tx-1"
  end
end
