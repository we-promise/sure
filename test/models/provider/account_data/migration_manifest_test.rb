require "minitest/autorun"
require "set"
require_relative "../../../../app/models/provider"
require_relative "../../../../app/models/provider/account_data"
require_relative "../../../../app/models/provider/account_data/migration_manifest"

class Provider::AccountData::MigrationManifestTest < Minitest::Test
  Manifest = Provider::AccountData::MigrationManifest
  Column = Struct.new(:type, :null, :default, :precision, :scale, :default_function, :array, keyword_init: true)

  def test_every_legacy_table_and_offering_has_a_manifest
    schema = File.read(File.expand_path("../../../../db/schema.rb", __dir__))
    tables = schema.scan(/^  create_table "([^"]+)"/).flatten
    providers = tables.grep(/_items\z/).map { |table| table.delete_suffix("_items") }
                      .select { |key| tables.include?("#{key}_accounts") }

    assert_equal providers.sort, Manifest.provider_keys.sort
    assert_equal 23, Manifest.all.size
    assert_equal 24, Manifest.offering_keys.size
    assert_equal "plaid", Manifest.for("plaid_eu").provider_key

    metadata = File.read(File.expand_path("../../../../app/models/provider/metadata.rb", __dir__))
    offerings = metadata.scan(/^\s+(\w+):\s+\{ region:/).flatten
    assert_equal offerings.sort, Manifest.offering_keys
  end

  def test_schema_columns_are_classified_exactly_once_and_encryption_is_not_downgraded
    schema = File.read(File.expand_path("../../../../db/schema.rb", __dir__))
    Manifest.all.each do |manifest|
      { item: manifest.item_table, account: manifest.account_table }.each do |kind, table|
        body = schema.match(/^  create_table "#{Regexp.escape(table)}".*?^  end/m)[0]
        columns = [ "id" ] + body.scan(/^    t\.(?:uuid|string|text|datetime|date|decimal|integer|bigint|jsonb|boolean) "([^"]+)"/).flatten
        # The working-tree schema remains the legacy baseline until migrations
        # are explicitly executed. Include only the reviewed additive columns.
        if table == "simplefin_items" && !columns.include?("credential_revision")
          migration = File.read(File.expand_path("../../../../db/migrate/20260916000100_add_simplefin_credential_revision.rb", __dir__))
          assert_includes migration, "add_column :simplefin_items, :credential_revision, :bigint, null: false, default: 0"
          columns << "credential_revision"
        end
        if table == "questrade_accounts"
          migration = File.read(File.expand_path("../../../../db/migrate/20260916000900_retain_questrade_activity_requests.rb", __dir__))
          { "activities_fetch_request" => "jsonb", "activities_fetch_revision" => "bigint", "activities_fetch_due_at" => "datetime" }.each do |name, type|
            assert_includes migration, "add_column :questrade_accounts, :#{name}, :#{type}"
            columns << name unless columns.include?(name)
          end
        end
        model = File.read(File.expand_path("../../../../app/models/#{table.delete_suffix('s')}.rb", __dir__))
        encrypted = model.scan(/encrypts :([a-z_]+)/).flatten

        assert manifest.validate_columns!(kind, columns, encrypted_columns: encrypted), table
      end
    end
  end

  def test_new_or_removed_columns_block_copy_before_any_values_are_read
    manifest = Manifest.for("up")
    source = source_record(manifest, :item, "access_token" => "private-token")
    source.class.columns_hash["new_secret"] = Column.new(type: :text, null: true)

    error = assert_raises(Manifest::InvalidSource) { manifest.extract_item(source) }
    assert_includes error.message, "new_secret"
    assert_empty source.reads
    refute_includes error.message, "private-token"

    source.class.columns_hash.delete("new_secret")
    source.class.columns_hash.delete("access_token")
    assert_raises(Manifest::InvalidSource) { manifest.extract_item(source) }
    assert_empty source.reads
  end

  def test_a_newly_encrypted_metadata_column_cannot_be_copied_to_plaintext
    manifest = Manifest.for("up")
    assert_raises(Manifest::InvalidSource) do
      manifest.validate_columns!(:item, manifest.columns(:item), encrypted_columns: [ "institution_name" ])
    end
  end

  def test_extracts_decoded_attributes_without_calling_custom_or_raw_readers
    manifest = Manifest.for("snaptrade")
    persisted = Time.utc(2024, 2, 3, 4, 5, 6)
    source = source_record(manifest, :item,
      "oauth_access_token" => "decrypted-token", "last_synced_at" => persisted,
      "raw_payload" => { "retained" => true })
    source.class.encrypted_attributes = Set.new(%w[oauth_access_token])
    source.define_singleton_method(:last_synced_at) { raise "Do not replace persisted state with derived Sync history" }
    source.define_singleton_method(:attributes_before_type_cast) { raise "Do not copy ciphertext" }

    projection = manifest.extract_item(source)

    assert_equal "decrypted-token", projection.credentials["oauth_access_token"]
    assert_equal persisted, projection.checkpoints["last_synced_at"]
    assert_equal({ "retained" => true }, projection.payloads["raw_payload"])
    assert_equal manifest.columns(:item).sort, source.reads.sort
    refute_includes projection.inspect, "decrypted-token"
    refute projection.metadata.key?("oauth_access_token")
  end

  def test_preserves_decimal_precision_null_empty_false_and_source_column_defaults
    manifest = Manifest.for("coinbase")
    amount = BigDecimal("1234567890123456.123456789012345678")
    source = source_record(manifest, :account,
      "account_id" => "coin-wallet", "current_balance" => amount,
      "raw_payload" => nil, "raw_transactions_payload" => [])
    source.class.columns_hash["current_balance"] = Column.new(type: :decimal, null: true, precision: 34, scale: 18)

    projection = manifest.extract_account(source)

    assert_equal amount, projection.attributes["current_balance"]
    assert_nil projection.payloads["raw_payload"]
    assert_equal [], projection.payloads["raw_transactions_payload"]
    assert_equal 34, projection.column_metadata["current_balance"]["precision"]
    assert_equal 18, projection.column_metadata["current_balance"]["scale"]

    up = Manifest.for("up")
    up_source = source_record(up, :account, "account_id" => "up-1", "ignored" => false)
    up_source.class.columns_hash["ignored"] = Column.new(type: :boolean, null: false, default: "false")
    up_projection = up.extract_account(up_source)
    assert_equal false, up_projection.settings["ignored"]
    assert_equal false, up_projection.column_metadata["ignored"]["null"]
    assert_equal "false", up_projection.column_metadata["ignored"]["default"]
  end

  def test_rejects_a_decimal_that_shared_columns_cannot_store
    manifest = Manifest.for("coinbase")
    source = source_record(manifest, :account, "account_id" => "wallet")
    source.class.columns_hash["current_balance"] = Column.new(type: :decimal, precision: 42, scale: 20)

    assert_raises(Manifest::InvalidSource) { manifest.extract_account(source) }
    assert_empty source.reads
  end

  def test_composite_identity_retains_case_nulls_and_separator_boundaries
    manifest = Manifest.for("coinstats")
    first = manifest.extract_account(source_record(manifest, :account, "account_id" => "a:b", "wallet_address" => "C"))
    second = manifest.extract_account(source_record(manifest, :account, "account_id" => "a", "wallet_address" => "b:C"))
    exchange = manifest.extract_account(source_record(manifest, :account, "account_id" => "portfolio", "wallet_address" => nil))

    refute_equal first.external_id, second.external_id
    assert_equal [ [ "account_id", "a:b" ], [ "wallet_address", "C" ] ], JSON.parse(first.external_id)
    assert_equal [ [ "account_id", "portfolio" ], [ "wallet_address", nil ] ], JSON.parse(exchange.external_id)
  end

  def test_onchain_identity_and_ingestion_namespace_are_independent_of_new_storage_ids
    manifest = Manifest.for("onchain_wallet")
    source = source_record(manifest, :account,
      "id" => "legacy-row", "chain" => "solana", "asset_kind" => "spl",
      "wallet_address" => "CaseSensitiveWallet", "contract_address" => "CaseSensitiveMint")
    projection = manifest.extract_account(source)

    assert_equal "onchain_legacy-row", projection.ingestion_namespace
    assert_includes projection.external_id, "CaseSensitiveWallet"
    assert_equal "connection", projection.identity_namespace
    refute projection.unresolved_identity?

    native = source_record(manifest, :account,
      "chain" => "bitcoin", "asset_kind" => "native", "wallet_address" => "Address", "contract_address" => nil)
    refute manifest.extract_account(native).unresolved_identity?
  end

  def test_simplefin_credential_revision_is_retained_as_metadata
    manifest = Manifest.for("simplefin")
    source = source_record(manifest, :item, "access_url" => "private-url", "credential_revision" => 7)
    source.class.columns_hash["credential_revision"] = Column.new(type: :bigint, null: false, default: "0")

    projection = manifest.extract_item(source)

    assert_equal 7, projection.metadata.fetch("credential_revision")
    assert_equal "private-url", projection.credentials.fetch("access_url")
    refute projection.credentials.key?("credential_revision")
    assert_equal false, projection.column_metadata.fetch("credential_revision").fetch("null")
  end

  def test_missing_upstream_identity_remains_unresolved_without_inventing_an_id
    manifest = Manifest.for("simplefin")
    projection = manifest.extract_account(source_record(manifest, :account, "id" => "legacy-only", "account_id" => nil))

    assert projection.unresolved_identity?
    assert_nil projection.external_id
    assert_equal "legacy-only", projection.source_id
  end

  def test_enable_banking_identity_uses_stable_hash_and_separates_grant_fields
    manifest = Manifest.for("enable_banking")
    projection = manifest.extract_account(source_record(manifest, :account,
      "uid" => "stable-hash", "account_id" => "rotating-api-uid", "iban" => "private-iban"))

    assert_equal "stable-hash", projection.external_id
    assert_equal "rotating-api-uid", projection.identity["account_id"]
    assert_equal "private-iban", projection.sensitive_data["iban"]
    assert manifest.authorization_required?
    assert_includes manifest.authorization_fields, "session_id"
    refute_includes manifest.authorization_fields, "client_certificate"
    refute Manifest.for("simplefin").authorization_required?
  end

  def test_synthetic_account_identities_do_not_depend_on_optional_api_ids
    binance = Manifest.for("binance")
    assert_equal "combined", binance.extract_account(source_record(binance, :account, "account_type" => "combined")).external_id
    trade_republic = Manifest.for("trade_republic")
    assert_equal "cash", trade_republic.extract_account(source_record(trade_republic, :account,
      "kind" => "cash", "trade_republic_account_id" => nil)).external_id
  end

  def test_target_credential_assignment_requires_an_encryptor_and_never_mutates_source
    target_class = Class.new do
      class << self
        attr_accessor :encrypted_attributes
      end
      attr_accessor :credentials
    end
    target = target_class.new
    values = { "token" => "plaintext-from-source-decryptor" }

    assert_raises(Manifest::EncryptionRequired) do
      Manifest.assign_encrypted!(target, attribute: :credentials, values: values)
    end
    assert_nil target.credentials

    target_class.encrypted_attributes = Set.new([ :credentials ])
    assert_same target, Manifest.assign_encrypted!(target, attribute: :credentials, values: values)
    assert_equal values, target.credentials
    refute_same values, target.credentials
    values["token"].replace("changed")
    assert_equal "plaintext-from-source-decryptor", target.credentials["token"]
  end

  private
    def source_record(manifest, kind, values)
      names = manifest.columns(kind)
      table = kind == :item ? manifest.item_table : manifest.account_table
      klass = Class.new do
        class << self
          attr_accessor :table_name, :columns_hash, :encrypted_attributes
        end
        attr_reader :reads

        define_method(:initialize) do |attributes|
          @values = attributes
          @reads = []
        end

        define_method(:read_attribute) do |name|
          @reads << name
          @values.fetch(name)
        end
      end
      klass.table_name = table
      klass.columns_hash = names.to_h { |name| [ name, Column.new(type: :string, null: true) ] }
      klass.encrypted_attributes = Set.new
      klass.new(names.to_h { |name| [ name, nil ] }.merge("id" => "source-id").merge(values))
    end
end
