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

  test "a clean non-dry-run completion marks the backfill flag complete" do
    Setting.encryption_backfill_completed_version = 0

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    assert_equal ActiveRecordEncryptionConfig::CURRENT_BACKFILL_VERSION, Setting.encryption_backfill_completed_version
  end

  test "a dry run does not mark the backfill flag complete" do
    Setting.encryption_backfill_completed_version = 0

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "true") }

    assert_equal 0, Setting.encryption_backfill_completed_version
  end

  test "a run with failures does not mark the backfill flag complete" do
    Setting.encryption_backfill_completed_version = 0

    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Failure Test", api_key: "seed")
    item.save!(validate: false)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_items SET api_key = ? WHERE id = ?", "plaintext-key", item.id ]))

    # Force the write phase of this record's backfill to fail so failed_count > 0.
    LunchflowItem.any_instance.stubs(:api_key=).raises(StandardError, "simulated failure")

    invoke_backfill("500", "false")

    assert_equal 0, Setting.encryption_backfill_completed_version
  end

  # Regression test for a gap jjmata flagged: the task computed per-model
  # success correctly (enough to gate the completion flag above) but printed
  # a hardcoded ok: true and always exited zero regardless, so an operator or
  # deployment script checking only the exit code - not hand-parsing the JSON
  # - would believe a partially-failed backfill fully succeeded.
  test "a run with failures reports ok: false and exits non-zero" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Exit Status Test", api_key: "seed")
    item.save!(validate: false)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_items SET api_key = ? WHERE id = ?", "plaintext-key", item.id ]))

    LunchflowItem.any_instance.stubs(:api_key=).raises(StandardError, "simulated failure")

    out, _err, exit_status = invoke_backfill("500", "false")

    assert_equal 1, exit_status, "a failed backfill must exit non-zero so automation can detect it"
    assert_equal false, JSON.parse(out.lines.last)["ok"], "a failed backfill must report ok: false, not a blanket success"
  end

  test "a clean run reports ok: true and exits zero" do
    out, _err, exit_status = invoke_backfill("500", "true")

    assert_nil exit_status, "a successful (or dry) run must not exit the process"
    assert_equal true, JSON.parse(out.lines.last)["ok"]
  end

  # Regression test for a gap CodeRabbit flagged: without invalidating the flag
  # up front, a *previously completed* backfill's flag would survive a later
  # failed run untouched, letting ActiveRecordEncryptionConfig.backfill_completed?
  # keep reporting "complete" while this run's still-plaintext rows sit unencrypted.
  test "a run with failures invalidates a previously-set completion flag" do
    Setting.encryption_backfill_completed_version = ActiveRecordEncryptionConfig::CURRENT_BACKFILL_VERSION

    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Reinvalidate Test", api_key: "seed")
    item.save!(validate: false)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_items SET api_key = ? WHERE id = ?", "plaintext-key", item.id ]))

    LunchflowItem.any_instance.stubs(:api_key=).raises(StandardError, "simulated failure")

    invoke_backfill("500", "false")

    assert_equal 0, Setting.encryption_backfill_completed_version
  end

  # Regression test for a gap Codex flagged: SnaptradeAccount#raw_balances_payload
  # is an encrypted column (app/models/snaptrade_account.rb) but was missing from
  # this task's field list, so upgraded installs with plaintext balance data would
  # get marked "backfill complete" while that column was still readable-but-raw -
  # and once support_unencrypted_data turns off, reads of it raise.
  test "backfills SnaptradeAccount#raw_balances_payload" do
    account = snaptrade_accounts(:fidelity_401k)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE snaptrade_accounts SET raw_balances_payload = ?::jsonb WHERE id = ?",
      [ { "currency" => "USD", "cash" => 1500.0 } ].to_json, account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_kind_of Array, account.raw_balances_payload
    assert_equal "USD", account.raw_balances_payload.first["currency"]
    at_rest = account.read_attribute_before_type_cast(:raw_balances_payload).to_s
    refute_includes at_rest, "1500.0"
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

  # Regression test for a gap jjmata flagged: the previous test above only
  # checked that a `results` key exists for each of a hand-picked subset of
  # models, not that the *fields* backfilled for a model exactly match what
  # it actually `encrypts` - so a new encrypted field added to a model
  # without a matching manifest update (exactly the SnaptradeAccount#
  # raw_balances_payload gap fixed elsewhere in this file) would stay green
  # here forever. This asserts exact parity for every model in the manifest.
  test "backfill manifest exactly matches each model's encrypted attributes" do
    ActiveRecordEncryptionConfig::BACKFILL_MANIFEST.each do |key, (model_class_name, fields)|
      model_class = model_class_name.constantize

      assert_equal fields.sort, model_class.encrypted_attributes.to_a.sort,
        "#{model_class_name} (results[:#{key}]) has drifted from " \
        "ActiveRecordEncryptionConfig::BACKFILL_MANIFEST - update the manifest " \
        "and bump CURRENT_BACKFILL_VERSION together with whatever changed " \
        "#{model_class_name}'s `encrypts` declarations"
    end
  end

  private

    # The task now calls `exit 1` on a failed (non-dry-run) invocation.
    # capture_io's own `return` never runs if the block it wraps raises past
    # it, so plain `capture_io { ... invoke ... }` would make out/err
    # unreachable for a failing run - rescue inside the block instead, so
    # stdout is still captured and the exit status is still observable.
    def invoke_backfill(*args)
      exit_status = nil
      out, err = capture_io do
        begin
          Rake::Task["security:backfill_encryption"].invoke(*args)
        rescue SystemExit => e
          exit_status = e.status
        end
      end
      [ out, err, exit_status ]
    end
end
