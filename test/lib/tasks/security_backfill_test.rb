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

  # A plaintext column next to already-encrypted payloads on the same row must
  # still be converted.
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

  # The task finds encrypted models at runtime. Compare that against the
  # `encrypts` lines in app/models, so a model the discovery misses fails here
  # instead of keeping plaintext that raises once the keys are live.
  test "backfill covers every encrypts declaration in app/models" do
    declared = Hash.new { |hash, key| hash[key] = [] }
    Dir[Rails.root.join("app/models/**/*.rb")].each do |path|
      File.read(path).scan(/^\s*encrypts\s+((?::\w+\s*,\s*)*:\w+)/) do |(names)|
        model = path.delete_prefix("#{Rails.root.join("app/models")}/").delete_suffix(".rb").camelize.constantize
        declared[model.base_class.table_name].concat(names.scan(/\w+/))
      end
    end
    assert_operator declared.size, :>=, 50, "the encrypts scan found too few models"

    output = run_backfill(dry_run: true)
    results = output["results"]
    discovered = encrypted_models_for_backfill.to_h { |model| [ model.table_name, model.encrypted_attributes.map(&:to_s) ] }

    declared.each do |table, fields|
      assert results.key?(table), "security:backfill_encryption does not cover #{table}"
      assert_empty fields - discovered[table], "#{table}: fields missing from the backfill"
    end
    tables = encrypted_models_for_backfill.map(&:table_name)
    assert_equal tables.uniq, tables, "two encrypted models share a table; their results would overwrite each other"

    # Framework models (ActionText::EncryptedRichText) declare `encrypts`
    # themselves; only models defined in this app must be ApplicationRecords.
    app_dir = Rails.root.join("app").to_s
    outside = ActiveRecord::Base.descendants.reject { |model| model <= ApplicationRecord || model.abstract_class? }
      .select { |model| model.encrypted_attributes.present? }
      .select { |model| Object.const_source_location(model.name.to_s)&.first.to_s.start_with?(app_dir) }
    assert_empty outside.map(&:name), "encrypted models outside ApplicationRecord are not backfilled"
  end

  # One plaintext row per encrypted model, as left by an install that ran
  # without keys. After one run, every encrypted column of every table must
  # hold ciphertext that decrypts to the original value.
  test "backfill encrypts plaintext in every encrypted column of every table" do
    connection = ActiveRecord::Base.connection
    rows = encrypted_models_for_backfill.to_h { |model| [ model, insert_plaintext_row(model) ] }

    output = run_backfill(dry_run: false)
    results = output["results"]

    rows.each do |model, (id, plaintext)|
      assert_equal 0, results.dig(model.table_name, "failed_count"), "#{model.table_name}: #{results[model.table_name]}"
      record = model.find(id)
      plaintext.each do |field, value|
        expected = json_column?(model, field) ? JSON.parse(value) : value
        assert_equal expected, record.public_send(field), "#{model.name}##{field} must decrypt to its original value"
        raw = connection.select_value(model.unscoped.where(id: id).select(field).to_sql).to_s
        refute_includes raw, "backfill-probe", "#{model.name}##{field} must be stored as ciphertext"
        assert ActiveRecord::Encryption.encryptor.encrypted?(raw),
          "#{model.name}##{field} must hold an encryption envelope"
      end
    end
  end

  test "backfill leaves converted values readable on a rerun" do
    item = kraken_items(:one)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE kraken_items SET api_secret = ? WHERE id = ?", "plaintext-secret", item.id ]))

    run_backfill(dry_run: false)
    output = run_backfill(dry_run: false)

    assert_equal "plaintext-secret", item.reload.api_secret
    assert_equal 0, output.dig("results", "kraken_items", "failed_count")
  end

  # Ciphertext under keys the app no longer has (keys changed, or data
  # encrypted with keys derived from SECRET_KEY_BASE) reads back as the raw
  # envelope. Encrypting that again would make the original unrecoverable.
  test "backfill refuses ciphertext that no configured key decrypts" do
    item = kraken_items(:one)
    foreign_key = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(SecureRandom.hex(32))
    foreign_text = ActiveRecord::Encryption.encryptor.encrypt("lost-secret", key_provider: foreign_key)
    foreign_json = ActiveRecord::Encryption.encryptor.encrypt({ "lost" => true }.to_json, key_provider: foreign_key)
    other = kraken_items(:requires_update)
    # Rails stores encrypted json/jsonb values as a JSON object envelope.
    KrakenItem.where(id: item.id).update_all([ "api_secret = ?", foreign_text ])
    KrakenItem.where(id: other.id).update_all([ "raw_payload = ?::jsonb", foreign_json ])

    preview = run_backfill(dry_run: true)
    assert_equal 2, preview.dig("results", "kraken_items", "failed_count"),
      "the dry run must report the rows the real run refuses"

    result = run_backfill(dry_run: false)
    assert_equal false, result["ok"]
    assert_equal 2, result["failed_count"]
    assert_equal 2, result.dig("results", "kraken_items", "failed_count")
    connection = ActiveRecord::Base.connection
    assert_equal foreign_text, connection.select_value(KrakenItem.where(id: item.id).select(:api_secret).to_sql)
    assert_equal JSON.parse(foreign_json),
      JSON.parse(connection.select_value(KrakenItem.where(id: other.id).select("raw_payload::text").to_sql))
  end

  test "backfill encrypts session user agents and hashes legacy IP addresses" do
    session = sessions(:one)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE sessions SET user_agent = ?, ip_address = ?, ip_address_digest = NULL WHERE id = ?",
      "Probe-Agent/1.0", "198.51.100.4", session.id ]))

    output = run_backfill(dry_run: false)
    results = output["results"]

    session.reload
    assert_equal "Probe-Agent/1.0", session.user_agent
    refute_includes session.read_attribute_before_type_cast(:user_agent).to_s, "Probe-Agent"
    assert_equal Digest::SHA256.hexdigest("198.51.100.4"), session.ip_address_digest
    assert_equal 0, results.dig("sessions", "failed_count")
    assert_equal 0, results.dig("session_ip_digests", "failed_count")
  end

  # Encryptor#encrypted? only checks for a "p" key; a plaintext payload of
  # that shape must still be converted, not refused.
  test "backfill converts plaintext json that only resembles an envelope" do
    item = kraken_items(:one)
    payload = { "p" => nil, "h" => "header" }
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE kraken_items SET raw_payload = ?::jsonb WHERE id = ?", payload.to_json, item.id ]))

    output = run_backfill(dry_run: false)

    assert_equal 0, output.dig("results", "kraken_items", "failed_count")
    assert_equal payload, item.reload.raw_payload
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

  test "backfills plaintext FioAccount IBAN" do
    account = fio_accounts(:checking)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE fio_accounts SET iban = ? WHERE id = ?", "CZ-PLAINTEXT-IBAN", account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    assert_equal "CZ-PLAINTEXT-IBAN", account.reload.iban
    refute_includes account.read_attribute_before_type_cast(:iban).to_s, "CZ-PLAINTEXT-IBAN"
  end

  # Pins the manifest's content to CURRENT_BACKFILL_VERSION: a manifest change
  # without a version bump would leave installs that completed the previous
  # backfill marked "complete", turning off the plaintext fallback for fields
  # their backfill never touched. On a deliberate change, bump the version and
  # add its digest here.
  BACKFILL_MANIFEST_DIGESTS = {
    4 => "9630168637fae661a583b828adb447e990416c8eae8b5f12eeaf1dad428acfb2",
    5 => "aef59eef15fde2bc5f8e12079235e86b586564755fa86f7459c7fd087c27ce71",
    6 => "8a7848cc0f0f829ebf0c9a54d349640696bb4e24f7f1e1e4b8bd5827e6f1fdd1",
    7 => "362ec2acfad421eaf6299bdeae78d859e13f8d4a65b6a3e615a80b274219698a",
    8 => "a4d113aa214e8754361484267d377174b2aeda3fe01c5ca0c553f9ab76ef2ab0",
    9 => "9f814939a5125a6903d9ba4e96392056ffafe9f6110b10b5c1cae0d87a564ac7",
    10 => "0bcaa72ed675acde5d5ae2ce72305bf73375c0faa5580fe80e3985e88aa4f9e4",
    11 => "a699ef0bad8187a616711dc392b7ac29bc5abe16bfe3e4134ef4de0c1d47eeb4"
  }.freeze

  test "backfill manifest changes come with a CURRENT_BACKFILL_VERSION bump" do
    digest = Digest::SHA256.hexdigest(ActiveRecordEncryptionConfig::BACKFILL_MANIFEST.sort.to_h.to_json)

    assert_equal BACKFILL_MANIFEST_DIGESTS[ActiveRecordEncryptionConfig::CURRENT_BACKFILL_VERSION], digest,
      "BACKFILL_MANIFEST changed - bump CURRENT_BACKFILL_VERSION and record the new digest (#{digest})"
  end

  test "covers every provider item and account model, not just the original subset" do
    out, _err = capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "true") }
    results = JSON.parse(out.lines.last)["results"]

    # Sanity check for models that were missing from this task's coverage
    # entirely before this change (would leave plaintext data with no
    # remediation path even after the encryption_ready? gating bug is fixed).
    %w[
      akahu_items binance_items brex_items coinbase_items coinspot_items coinstats_items
      fio_items ibkr_items indexa_capital_items kraken_items mercury_items monobank_items
      onchain_wallet_items questrade_items redbark_items snaptrade_items
      sophtron_items trade_republic_items trading212_items up_items wise_items
      akahu_accounts binance_accounts brex_accounts coinspot_accounts fio_accounts ibkr_accounts
      indexa_capital_accounts kraken_accounts monobank_accounts onchain_wallet_accounts
      questrade_accounts redbark_accounts sophtron_accounts trade_republic_accounts
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

  # The parity test above only checks models already listed in the manifest,
  # so a model that encrypts fields but was never added (Fio, Monobank and
  # Coinspot, previously) passed silently - and once the completed backfill
  # turns off the legacy-plaintext fallback, its old rows raise on read.
  # Session is excluded on purpose, see BACKFILL_MANIFEST's comment.
  test "every model with encrypted attributes is in the backfill manifest" do
    Rails.application.eager_load!

    manifest = ActiveRecordEncryptionConfig::BACKFILL_MANIFEST.values.to_h
    # Named, loadable classes only: anonymous test-only subclasses aren't real models.
    encrypted_models = ApplicationRecord.descendants.select do |model|
      !model.abstract_class? && model.name&.safe_constantize == model && model.encrypted_attributes.present?
    end

    encrypted_models.each do |model|
      next if model.base_class.name == "Session"

      fields = manifest[model.base_class.name]
      assert fields, "#{model.name} encrypts #{model.encrypted_attributes.to_a.sort.inspect} but is missing from " \
        "ActiveRecordEncryptionConfig::BACKFILL_MANIFEST - add it and bump CURRENT_BACKFILL_VERSION"
      assert_empty model.encrypted_attributes.to_a - fields,
        "#{model.name} encrypts fields the backfill manifest does not cover"
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

  test "backfill encrypts a legacy plaintext enable banking iban" do
    item = EnableBankingItem.create!(family: families(:dylan_family), name: "Backfill EB",
      country_code: "FR", application_id: "app_id", client_certificate: "cert")
    account = item.enable_banking_accounts.create!(name: "Backfill EB Account", uid: "backfill-eb-1", currency: "EUR")
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE enable_banking_accounts SET iban = ? WHERE id = ?", "nl91 abna 0417 1643 00", account.id ])) # pipelock:ignore IBAN

    invoke_backfill("500", "false")

    account.reload
    assert_equal "NL91ABNA0417164300", account.iban # pipelock:ignore IBAN
    assert_match(/"p":/, account.read_attribute_before_type_cast(:iban).to_s)
  end

  private

    def encrypted_models_for_backfill
      ActiveRecordEncryptionConfig::BACKFILL_MANIFEST.values.map { |name, _| name.constantize } + [ Session ]
    end

    # Runs the task like an operator would and returns its JSON report. The
    # task exits 1 when rows fail, which must not end the test process.
    def run_backfill(dry_run:)
      task = Rake::Task["security:backfill_encryption"]
      task.reenable
      output, = capture_io do
        task.invoke("500", dry_run.to_s)
      rescue SystemExit
        nil
      end
      JSON.parse(output.lines.last)
    end

    def json_column?(model, field)
      %i[json jsonb].include?(model.columns_hash[field.to_s].type)
    end

    # Writes plaintext into every encrypted column with raw SQL: into a
    # fixture row where the table has one (so its check constraints hold),
    # otherwise into a new row with placeholder values.
    def insert_plaintext_row(model)
      plaintext = model.encrypted_attributes.to_h do |field|
        value = json_column?(model, field) ? { "probe" => "backfill-probe-#{field}" }.to_json : "backfill-probe-#{field}"
        [ field.to_s, value ]
      end

      id = model.unscoped.order(:id).pick(:id)
      if id
        model.unscoped.where(id: id).update_all(plaintext.keys.map { |field| "#{model.connection.quote_column_name(field)} = ?" }
          .join(", ").then { |sql| [ sql, *plaintext.values ] })
      else
        id = insert_row(model.table_name, plaintext, fresh_parents: true)
      end
      [ id, plaintext ]
    end

    # fresh_parents: a new parent row per foreign key, so unique indexes that
    # span the parent (one account per item and kind, ...) are not hit.
    def insert_row(table, given = {}, fresh_parents: false)
      connection = ActiveRecord::Base.connection
      references = connection.foreign_keys(table).to_h { |fk| [ fk.column, fk.to_table ] }

      values = connection.columns(table).each_with_object({}) do |column, map|
        next if given.key?(column.name) || column.null || !column.default.nil? || column.default_function
        map[column.name] =
          if references.key?(column.name)
            fresh_parents ? insert_row(references[column.name]) : existing_or_new_row(references[column.name])
          else
            placeholder_for(table, column)
          end
      end.merge(given)

      columns = values.keys.map { |name| connection.quote_column_name(name) }.join(", ")
      quoted = values.values.map { |value| connection.quote(value) }.join(", ")
      connection.select_value("INSERT INTO #{connection.quote_table_name(table)} (#{columns}) VALUES (#{quoted}) RETURNING id")
    end

    def existing_or_new_row(table)
      ActiveRecord::Base.connection.select_value("SELECT id FROM #{ActiveRecord::Base.connection.quote_table_name(table)} LIMIT 1") ||
        insert_row(table)
    end

    def placeholder_for(table, column)
      # A check constraint that limits the column to a list of values
      # ("kind::text = ANY (ARRAY['wallet'::...])") names a valid one.
      allowed = ActiveRecord::Base.connection.check_constraints(table).lazy.filter_map do |constraint|
        constraint.expression[/\b#{column.name}::[\w ]+= (?:ANY \(ARRAY\[)?'([^']*)'/, 1]
      end.first
      return allowed if allowed

      case column.type
      when :uuid then SecureRandom.uuid
      when :integer, :bigint, :decimal, :float then 0
      when :boolean then false
      when :date then Date.current
      when :datetime, :timestamp then Time.current
      when :json, :jsonb then "{}"
      when :enum then ActiveRecord::Base.connection.select_value("SELECT unnest(enum_range(NULL::#{column.sql_type})) LIMIT 1")
      else column.array? ? "{}" : "backfill-placeholder-#{SecureRandom.hex(4)}"
      end
    end

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
