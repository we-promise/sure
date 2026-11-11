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

  test "backfill encrypts provider account identifiers stored as plaintext" do
    eb_item = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Backfill EB", country_code: "FI", application_id: "app", client_certificate: "cert"
    )
    akahu_account = AkahuAccount.create!(
      akahu_item: AkahuItem.create!(family: families(:dylan_family), name: "Backfill Akahu", app_token: "app", user_token: "user"),
      name: "Everyday", account_id: "acc_backfill", currency: "NZD"
    )

    # Plaintext values, as left by an install that synced before these columns were encrypted
    connection = ActiveRecord::Base.connection
    connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE enable_banking_items SET last_psu_ip = ? WHERE id = ?", "203.0.113.7", eb_item.id ]))
    connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE akahu_accounts SET formatted_account = ? WHERE id = ?", "12-3456-7654321-00", akahu_account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    assert_equal "203.0.113.7", eb_item.reload.last_psu_ip
    assert_equal "12-3456-7654321-00", akahu_account.reload.formatted_account
    refute_includes eb_item.read_attribute_before_type_cast(:last_psu_ip).to_s, "203.0.113.7"
    refute_includes akahu_account.read_attribute_before_type_cast(:formatted_account).to_s, "7654321"
  end

  # The backfill loads a batch, then encrypts each row. DataCleanerJob may
  # clear last_psu_ip in between; writing the value read before that would
  # put the IP back. The filter block runs on the loaded record before the
  # write, so it stands in for that concurrent clear.
  test "backfill does not restore a value cleared after the batch was loaded" do
    eb_item = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Backfill EB race", country_code: "FI", application_id: "app", client_certificate: "cert"
    )
    connection = ActiveRecord::Base.connection
    connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE enable_banking_items SET last_psu_ip = ? WHERE id = ?", "203.0.113.9", eb_item.id ]))

    backfill_model(EnableBankingItem.where(id: eb_item.id), %i[last_psu_ip], 500, false) do |record|
      record.class.where(id: record.id).update_all(last_psu_ip: nil)
      true
    end

    assert_nil eb_item.reload.read_attribute_before_type_cast(:last_psu_ip)
  end

  # Guards the task's field list: dropping :account_number from the
  # SnaptradeAccount entry would leave the model-level encryption test green
  # while pre-encryption rows stayed plaintext.
  test "backfill encrypts a plaintext SnapTrade account number" do
    account = snaptrade_accounts(:fidelity_401k)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE snaptrade_accounts SET account_number = ? WHERE id = ?", "5544332211", account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    assert_equal "5544332211", account.reload.account_number
    at_rest = ActiveRecord::Base.connection.select_value(
      SnaptradeAccount.where(id: account.id).select(:account_number).to_sql)
    refute_includes at_rest.to_s, "5544332211",
      "account_number must be stored as ciphertext after the backfill"
  end

  # Several payload columns default to {} — Rails presence checks treat empty
  # Hash/Array as absent, so the backfill must gate on nil-ness or empty
  # payloads stay plaintext and raise on every read once keys are live.
  test "backfill encrypts empty json payloads" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Empty Test", api_key: "seed")
    item.save!(validate: false)
    account = item.lunchflow_accounts.create!(
      name: "Backfill Empty Test Account", currency: "GBP", account_id: "backfill-test-2")

    # Plaintext empty payload, as left by a pre-encryption install
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_accounts SET raw_payload = ?::jsonb WHERE id = ?", "{}", account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_equal({}, account.raw_payload,
      "an empty payload must decrypt cleanly after the backfill, not remain plaintext")
    assert_match(/"p":/, account.read_attribute_before_type_cast(:raw_payload).to_s,
      "the stored value must be an encryption envelope, not plaintext {}")
  end

  test "covers every provider item and account model, not just the original subset" do
    out, _err = capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "true") }
    results = JSON.parse(out.lines.last)["results"]

    # Sanity check for models that were missing from this task's coverage
    # entirely before this change (would leave plaintext data with no
    # remediation path even after the encryption_ready? gating bug is fixed).
    %w[
      akahu_items binance_items brex_items coinbase_items coinstats_items
      ibkr_items indexa_capital_items kraken_items mercury_items
      onchain_wallet_items questrade_items redbark_items snaptrade_items
      sophtron_items trading212_items up_items wise_items
      akahu_accounts binance_accounts brex_accounts ibkr_accounts
      indexa_capital_accounts kraken_accounts onchain_wallet_accounts
      questrade_accounts redbark_accounts sophtron_accounts
      trading212_accounts up_accounts wise_accounts
      api_keys sso_providers sso_identity_blocks
    ].each do |key|
      assert results.key?(key), "expected security:backfill_encryption to cover #{key}"
    end
  end

  # Rails encrypts deterministic attributes with the oldest configured scheme
  # while `previous` schemes exist. A rotation away from a compromised key
  # must still move them to the current key.
  test "backfill re-encrypts deterministic values under the current key during a rotation" do
    old_key_provider = ActiveRecord::Encryption::DeterministicKeyProvider.new(SecureRandom.hex(32))
    probe_class = Class.new(ApplicationRecord) do
      self.table_name = "invite_codes"
      def self.name = "InviteCodeRotationProbe"
      encrypts :token, deterministic: true, previous: [ { deterministic: true, key_provider: old_key_provider } ]
    end
    current_key_provider = probe_class.type_for_attribute(:token).key_provider
    encryptor = ActiveRecord::Encryption.encryptor

    record = probe_class.create!(token: "rotation-probe-token")
    old_ciphertext = record.read_attribute_before_type_cast(:token)
    assert_equal "rotation-probe-token", encryptor.decrypt(old_ciphertext, key_provider: old_key_provider)
    assert_raises(ActiveRecord::Encryption::Errors::Decryption) do
      encryptor.decrypt(old_ciphertext, key_provider: current_key_provider)
    end

    backfill_model(probe_class.where(id: record.id), %i[token], 500, false)

    new_ciphertext = probe_class.connection.select_value(
      probe_class.where(id: record.id).select(:token).to_sql)
    assert_equal "rotation-probe-token", encryptor.decrypt(new_ciphertext, key_provider: current_key_provider)
    assert_raises(ActiveRecord::Encryption::Errors::Decryption) do
      encryptor.decrypt(new_ciphertext, key_provider: old_key_provider)
    end
  end

  # support_unencrypted_data returns ciphertext that no configured key
  # decrypts as if it were plaintext. Encrypting that again would make the
  # original value unrecoverable.
  test "backfill refuses ciphertext that no configured key decrypts" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Foreign Key", api_key: "seed")
    item.save!(validate: false)
    foreign = ActiveRecord::Encryption.encryptor.encrypt(
      "lost-key", key_provider: ActiveRecord::Encryption::DeterministicKeyProvider.new(SecureRandom.hex(32)),
      cipher_options: { deterministic: true }
    )
    LunchflowItem.where(id: item.id).update_all([ "api_key = ?", foreign ])

    result = backfill_model(LunchflowItem.where(id: item.id), %i[api_key], 500, false)

    assert_equal 1, result[:failed_count]
    assert_equal foreign, LunchflowItem.where(id: item.id).pick(Arel.sql("api_key"))
  end
end
