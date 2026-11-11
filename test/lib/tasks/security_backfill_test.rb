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

    outside = ActiveRecord::Base.descendants.reject { |model| model <= ApplicationRecord || model.abstract_class? }
      .select { |model| model.encrypted_attributes.present? }
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

  private

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
end
