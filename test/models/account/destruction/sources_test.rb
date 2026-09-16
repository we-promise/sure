require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"
require_relative "../../../support/retained_account_index_test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Account::Destruction::SourcesTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper

  Sources = Account::Destruction::Sources
  NativeSource = Data.define(:connection, :external, :link, :policy)

  test "direct legacy links and polymorphic links retain their exact owning items" do
    root = accounts(:connected)
    item = UpItem.create!(family: root.family, name: "Legacy source", access_token: "private-legacy-token")
    source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Legacy account", currency: "USD", current_balance: 10)
    AccountProvider.create!(account: root, provider: source)

    result = Sources.capture(account: root)

    assert_includes result.legacy_items, [ "PlaidItem", plaid_items(:one).id ]
    assert_includes result.legacy_items, [ "UpItem", item.id ]
    assert_includes result.legacy_accounts, [ "PlaidAccount", plaid_accounts(:one).id, plaid_items(:one).id ]
    assert_includes result.legacy_accounts, [ "UpAccount", source.id, item.id ]
    assert_empty result.connection_ids
    assert_empty result.external_ids
    refute_includes result.proof.to_json, "private-legacy-token"
  end

  test "account Sync ownership remains in the inventory and cannot follow a reparented account" do
    root = financial_account
    sync = root.syncs.create!

    result = Sources.capture(account: root)

    captured = result.proof.fetch("syncs").find { |row| row.fetch("id") == sync.id }
    assert_equal root.family_id, captured.fetch("account_family_id")
    original_family_id = root.family_id
    Account.where(id: root.id).update_all(family_id: families(:empty).id)

    assert_raises(Sources::InvalidGraph) { Sources.capture(account: root.reload) }
    assert_equal original_family_id, sync.reload.account_family_id
  end

  test "all source policy revisions and independently linked providers remain in the inventory" do
    with_provider_encryption do
      root = financial_account
      first = native_source(root)
      second = native_source(root, provider_key: "plaid", resource: "balances")
      previous = first.policy
      selected = Account::SourcePolicy.select!(account: root, account_provider: second.link, resource: "transactions")

      result = Sources.capture(account: root)

      assert_equal [ first.connection.id, second.connection.id ].sort, result.connection_ids
      assert_equal [ first.external.id, second.external.id ].sort, result.external_ids
      assert_includes proof_ids(result, "policies"), previous.id
      assert_includes proof_ids(result, "policies"), selected.id
      refute previous.reload.active?
      assert_empty result.legacy_items
      assert_empty result.legacy_accounts
    end
  end

  test "the surviving transfer counterpart contributes its independent provider owner" do
    with_provider_encryption do
      source = native_source(accounts(:credit_card))

      result = Sources.capture(account: accounts(:depository))

      assert_includes result.account_ids, accounts(:credit_card).id
      assert_includes result.connection_ids, source.connection.id
      assert_includes result.external_ids, source.external.id
      assert_includes result.proof.fetch("effects").fetch("entries").map { |row| row.fetch("id") }, entries(:transfer_in).id
    end
  end

  test "a retired source selection remains discoverable without a live link or published batch" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root)
      captured = source.policy.source_binding.deep_dup
      source.policy.update!(active: false)
      source.link.destroy!

      result = Sources.capture(account: root)

      assert_equal [ source.connection.id ], result.connection_ids
      assert_equal [ source.external.id ], result.external_ids
      assert_empty proof_ids(result, "links")
      assert_empty proof_ids(result, "batches")
      assert_equal captured, result.proof.fetch("policies").sole.fetch("source_binding")
      assert_equal source.policy.id, result.proof.fetch("owners").fetch("retained_sources").sole.fetch("id")
      assert source.policy.reload.persisted?
    end
  end

  test "a removed CoinStats tracking row keeps its originally selected item in the inventory" do
    root = financial_account
    item = CoinstatsItem.create!(family: root.family, name: "Selected portfolio", api_key: "private-source-key")
    tracking = item.coinstats_accounts.create!(account_id: SecureRandom.uuid, name: "Wallet", currency: "USD", current_balance: 20)
    link = AccountProvider.create!(account: root, provider: tracking)
    policy = Account::SourcePolicy.select!(account: root, account_provider: link, resource: "balances")
    policy.update!(active: false)
    link.destroy!
    refute CoinstatsAccount.exists?(tracking.id)

    result = Sources.capture(account: root)

    assert_includes result.legacy_items, [ "CoinstatsItem", item.id ]
    assert_includes result.legacy_accounts, [ "CoinstatsAccount", tracking.id, item.id ]
    assert_includes proof_ids(result, "policies"), policy.id
    assert result.proof.fetch("owners").fetch("legacy_accounts").sole.fetch("retained_missing")
    refute_includes result.proof.to_json, "private-source-key"
  end

  test "unknown historical policy ownership requires disposition even while its live link survives" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, select_policy: false)
      Account::IngestionIdentity.capture!(account: root)
      Account::SourcePolicy.insert_all!([ { id: SecureRandom.uuid, account_id: root.id, family_id: root.family_id,
        account_provider_id: source.link.id, resource: "transactions", revision: 1, active: false, source_binding: {} } ])

      assert_raises(Sources::Incomplete) { Sources.capture(account: root) }

      assert source.link.reload.persisted?
      assert_empty Account::SourcePolicy.find_by!(account_id: root.id).source_binding
    end
  end

  test "inactive entry evidence survives a lost live link and nil entry reference" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root)
      entry = transaction_entry(root)
      batch = retained_account_batch(source, root, stream: "transactions")
      observation = observation(source, batch: batch, account: root)
      evidence = EntrySource.create!(source_record: observation, family: root.family, account: root,
        entry: nil, entry_identity: entry.id, active: false, role: "evidence", match_method: "retained_source")
      source.policy.update!(active: false)
      source.link.destroy!

      result = Sources.capture(account: root)

      assert_equal [ source.connection.id ], result.connection_ids
      assert_includes proof_ids(result, "entry_sources"), evidence.id
      assert_includes proof_ids(result, "source_records"), observation.id
      assert_includes proof_ids(result, "batches"), batch.id
      assert_nil evidence.reload.entry_id
      refute evidence.active?
    end
  end

  test "inactive holding evidence survives without a current holding or account provider" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, resource: "holdings")
      batch = retained_account_batch(source, root, stream: "holdings")
      record = observation(source, batch: batch, account: root, kind: "holding")
      evidence = HoldingSource.create!(source_record: record, account: root, family: root.family,
        holding_identity: SecureRandom.uuid, holding: nil, active: false, role: "posting")
      source.policy.update!(active: false)
      source.link.destroy!

      result = Sources.capture(account: root)

      assert_equal [ source.connection.id ], result.connection_ids
      assert_includes proof_ids(result, "holding_sources"), evidence.id
      assert_includes proof_ids(result, "source_records"), record.id
      assert_includes proof_ids(result, "batches"), batch.id
    end
  end

  test "a detached fetching generation retains its original account before any fanout batch exists" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root)
      context = { "version" => 1, "accounts" => Provider::AccountData::GenerationAccounts.new(source.connection).capture }
      generation = source.connection.provider_sync_generations.create!(sync: source.connection.syncs.create!, writer_epoch: 0,
        context_snapshot: context, account_ids: [ root.id ])
      source.policy.update!(active: false)
      source.link.destroy!
      assert_empty source.connection.ingestion_batches
      ProviderSyncGeneration.any_instance.expects(:context_snapshot).never

      result = Sources.capture(account: root)

      assert_equal [ source.connection.id ], result.connection_ids
      assert_includes proof_ids(result, "generations"), generation.id
      assert_includes proof_ids(result, "syncs"), generation.sync_id
      assert_equal [ root.id ], generation.reload.account_ids
      assert generation.fetching?
    end
  end

  test "a balance batch and its inactive policy retain ownership after the current link disappears" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, resource: "balances")
      batch = retained_account_batch(source, root, stream: "balances")
      source.policy.update!(active: false)
      source.link.destroy!
      assert_empty SourceRecord.where(account: root)
      IngestionBatch.any_instance.expects(:payload).never

      result = Sources.capture(account: root)

      assert_equal [ source.connection.id ], result.connection_ids
      assert_includes result.external_ids, source.external.id
      assert_includes proof_ids(result, "batches"), batch.id
      assert_includes proof_ids(result, "policies"), source.policy.id
      assert_equal root.id, batch.reload.source_binding.fetch("account_id")
    end
  end

  test "an equity batch remains discoverable through its captured historical policy without source observations" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, provider_key: "ibkr", resource: "historical_balances")
      batch = account_batch(source, stream: "equity_snapshots", source_binding: {})
      source.policy.update!(active: false)
      assert_empty SourceRecord.where(account: root)

      result = Sources.capture(account: root)

      assert_includes result.connection_ids, source.connection.id
      assert_includes proof_ids(result, "policies"), source.policy.id
      assert_includes proof_ids(result, "batches"), batch.id
      refute source.policy.reload.active?
    end
  end

  test "a discarded captured policy cannot be reconstructed from a surviving batch binding" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, resource: "balances")
      batch = account_batch(source, stream: "balances")
      # Simulate evidence already lost outside the lifecycle command. Ordinary
      # link removal retains the immutable policy instead of cascading it.
      source.policy.delete
      source.link.destroy!

      assert_raises(Sources::Incomplete) { Sources.capture(account: root) }

      assert_equal root.id, batch.reload.source_binding.fetch("account_id")
      assert_equal source.policy.id, batch.source_policy_version
      refute Account::SourcePolicy.exists?(source.policy.id)
    end
  end

  test "historical commands cannot hide secondary policy references inside encrypted payloads" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, provider_key: "ibkr", resource: "historical_balances")
      batch = account_batch(source, stream: "opening_anchor_repairs", source_binding: {},
        payload: { "balance_policy_version" => SecureRandom.uuid })
      IngestionBatch.any_instance.expects(:payload).never

      assert_raises(Sources::Incomplete) { Sources.capture(account: root) }
      assert_equal source.policy.id, batch.source_policy_version
    end
  end

  test "inactive evidence cannot claim a surviving historical entry on another account" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root)
      elsewhere = transaction_entry(financial_account)
      batch = retained_account_batch(source, root, stream: "transactions")
      record = observation(source, batch: batch, account: root)
      EntrySource.create!(source_record: record, account: root, family: root.family,
        entry: nil, entry_identity: elsewhere.id, active: false, role: "evidence", match_method: "retained_source")

      assert_raises(Sources::InvalidGraph) { Sources.capture(account: root) }
      assert elsewhere.reload.persisted?
    end
  end

  test "historical calculation inputs and provider Sync ancestry are inventoried beyond the selected input" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, provider_key: "ibkr", resource: "historical_balances")
      ancestor = root.family.syncs.create!
      provider_sync = source.connection.syncs.create!(parent: ancestor)
      batch = account_batch(source, stream: "equity_snapshots", source_binding: {}, sync: provider_sync)
      first = calculation_input(root, source, batch)
      second = calculation_input(root, source, batch)
      Account::SyncSource.create!(account: root, family: root.family, resource: "historical_balances", account_sync_input: second)
      Account::SyncInput.any_instance.expects(:payload).never

      result = Sources.capture(account: root)

      assert_equal [ first.id, second.id ].sort, proof_ids(result, "sync_inputs")
      [ first.sync_id, second.sync_id, provider_sync.id, ancestor.id ].each do |id|
        assert_includes proof_ids(result, "syncs"), id
      end
      assert_includes result.connection_ids, source.connection.id
      assert_includes proof_ids(result, "batches"), batch.id
    end
  end

  test "destructive Sync descendants are followed without absorbing siblings of a surviving ancestor" do
    with_provider_encryption do
      root = financial_account
      ancestor = root.family.syncs.create!
      root_sync = root.syncs.create!(parent: ancestor)
      child_connection = create_provider_connection(family: root.family)
      child = child_connection.syncs.create!(parent: root_sync)
      sibling_connection = create_provider_connection(family: root.family)
      sibling = sibling_connection.syncs.create!(parent: ancestor)

      result = Sources.capture(account: root)

      assert_equal [ child_connection.id ], result.connection_ids
      assert_equal [ root_sync.id, child.id ].sort, result.proof.fetch("deleted_sync_ids")
      assert_includes proof_ids(result, "syncs"), ancestor.id
      refute_includes proof_ids(result, "syncs"), sibling.id
      refute_includes result.connection_ids, sibling_connection.id
    end
  end

  test "document evidence and import account mappings never invent a provider connection" do
    with_provider_encryption do
      root = financial_account
      statement = statement_header(root)
      imported = PdfImport.create!(family: root.family, account_statement: statement, account: root)
      mapped = TransactionImport.create!(family: root.family)
      mapping = Import::AccountMapping.create!(import: mapped, key: "Original checking", mappable: root)
      batch = IngestionBatch.create!(family: root.family, origin_kind: "file", import: imported, account_statement: statement,
        stream: "transactions", scope_key: "statement:#{statement.id}", idempotency_key: SecureRandom.uuid,
        mode: "snapshot", complete: true, payload: { "private" => "private-extracted-document" })
      record = SourceRecord.create!(family: root.family, account: root, account_statement: statement,
        ingestion_batch: batch, kind: "transaction", external_id: "row-1")

      result = Sources.capture(account: root)

      assert_equal [ statement.id ], result.document_ids
      assert_equal [ imported.id, mapped.id ].sort, result.import_ids
      assert_includes proof_ids(result, "import_mappings"), mapping.id
      assert_includes proof_ids(result, "source_records"), record.id
      assert_includes proof_ids(result, "batches"), batch.id
      assert_empty result.connection_ids
      assert_empty result.external_ids
      assert_empty result.legacy_items
      refute_includes result.proof.to_json, "private-extracted-document"
    end
  end

  test "unknown generation projections fail the family inventory instead of appearing unassociated" do
    with_provider_encryption do
      root = financial_account
      source = create_provider_connection(family: root.family)
      generation = source.provider_sync_generations.create!(sync: source.syncs.create!, writer_epoch: 0,
        context_snapshot: { "version" => 1, "accounts" => {} }, status: "abandoned")

      assert_raises(Sources::Incomplete) { Sources.capture(account: root) }
      assert_nil generation.reload.account_ids
      assert Sources.capture(account: financial_account(family: families(:empty)))
    end
  end

  test "missing or malformed batch routing blocks before filtering for the requested account" do
    with_provider_encryption do
      root = financial_account
      connection = create_provider_connection(family: root.family)
      external = create_external_account(connection)
      bindings = [ {}, {
        "account_id" => "private-unroutable-id", "account_provider_id" => SecureRandom.uuid,
        "external_account_id" => external.id, "resource" => "balances",
        "source_policy_version" => nil, "publication" => "retained"
      } ]
      bindings.each do |binding|
        batch = create_provider_batch(connection, external_account: external, stream: "balances",
          scope_key: "account:#{external.id}", source_binding: binding, source_policy_version: nil)

        error = assert_raises(Sources::Incomplete) { Sources.capture(account: root) }
        refute_includes error.message, "private-unroutable-id"
        assert batch.reload.persisted?
        batch.delete
        assert Sources.capture(account: root)
      end
    end
  end

  test "foreign direct legacy source and unknown or missing polymorphic owners are refused" do
    foreign = financial_account(family: families(:empty))
    foreign.update_columns(plaid_account_id: plaid_accounts(:one).id)
    assert_raises(Sources::InvalidGraph) { Sources.capture(account: foreign) }

    %w[UpAccount PrivateUnsupportedAccount].each do |type|
      root = financial_account
      link = AccountProvider.new(account: root, provider_type: type, provider_id: SecureRandom.uuid)
      link.save!(validate: false)
      error = assert_raises(Sources::InvalidGraph) { Sources.capture(account: root) }
      refute_includes error.message, "PrivateUnsupportedAccount"
    end
  end

  test "undeclared native provider ownership cannot silently become a manual account" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root, provider_key: "private_unregistered_provider", select_policy: false)

      error = assert_raises(Sources::InvalidGraph) { Sources.capture(account: root) }

      refute_includes error.message, "private_unregistered_provider"
      assert source.link.reload.persisted?
    end
  end

  test "a foreign import mapping or Sync ancestor cannot be hidden by a local account association" do
    with_provider_encryption do
      root = financial_account
      foreign_import = TransactionImport.create!(family: families(:empty))
      mapping = Import::AccountMapping.create!(import: foreign_import, key: "Foreign mapping", mappable: root)
      assert_raises(Sources::InvalidGraph) { Sources.capture(account: root) }
      mapping.destroy!

      source = native_source(root)
      foreign_parent = families(:empty).syncs.create!
      batch = account_batch(source, stream: "transactions", sync: source.connection.syncs.create!(parent: foreign_parent))
      observation(source, batch: batch, account: root)
      assert_raises(Sources::InvalidGraph) { Sources.capture(account: root) }
      assert_equal foreign_parent.id, batch.sync.reload.parent_id
    end
  end

  test "source discovery is frozen read only and detects header drift without decrypting payloads" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root)
      batch = account_batch(source, stream: "transactions", payload: { "private" => "private-raw-payload" })
      observation(source, batch: batch, account: root)
      before = [ root.reload.attributes, source.connection.reload.attributes, batch.reload.attributes ]
      ProviderConnection.any_instance.expects(:credentials).never
      IngestionBatch.any_instance.expects(:payload).never
      first = nil

      queries = capture_sql_queries { assert_no_enqueued_jobs { first = Sources.capture(account: root) } }

      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_empty queries.grep(/\bFOR\s+(?:UPDATE|SHARE|KEY SHARE|NO KEY UPDATE)\b/i)
      assert_equal "account-destruction-sources/v1", first.proof.fetch("format")
      assert_deep_frozen(first.proof)
      assert first.frozen?
      assert_equal before, [ root.reload.attributes, source.connection.reload.attributes, batch.reload.attributes ]
      refute_includes first.proof.to_json, "private-raw-payload"
      refute_includes first.proof.to_json, "private-provider-token"
      source.connection.update_columns(metadata: { "private" => "private-source-change" })
      second = Sources.capture(account: root)
      refute_equal first.proof, second.proof
      assert_equal first.connection_ids, second.connection_ids
      refute_includes second.proof.to_json, "private-source-change"
    end
  end

  test "row and Sync ancestry limits fail without returning a partial source set" do
    with_provider_encryption do
      root = financial_account
      source = native_source(root)
      parent = root.family.syncs.create!
      3.times { parent = root.family.syncs.create!(parent: parent) }
      batch = account_batch(source, stream: "transactions", sync: source.connection.syncs.create!(parent: parent))
      observation(source, batch: batch, account: root)

      with_limit(:MAX_ROWS, 1) { assert_raises(Sources::TooLarge) { Sources.capture(account: root) } }
      with_limit(:MAX_SYNC_DEPTH, 2) { assert_raises(Sources::TooLarge) { Sources.capture(account: root) } }
      with_limit(:MAX_ACCOUNTS, 1) { assert_raises(Sources::TooLarge) { Sources.capture(account: accounts(:depository)) } }
    end
  end

  private

    def financial_account(family: families(:dylan_family))
      family.accounts.create!(name: "Source inventory account", currency: "USD", balance: 0, accountable: Depository.new)
    end

    def transaction_entry(account)
      account.entries.create!(name: "Retained transaction", date: Date.current, amount: 10, currency: "USD", entryable: Transaction.new)
    end

    def native_source(account, provider_key: "up", resource: "transactions", select_policy: true)
      connection = create_provider_connection(family: account.family, provider_key: provider_key)
      external = create_external_account(connection)
      link = AccountProvider.create!(account: account, external_account: external)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource) if select_policy
      NativeSource.new(connection, external, link, policy)
    end

    def account_batch(source, stream:, **attributes)
      create_provider_batch(source.connection, external_account: source.external, stream: stream,
        scope_key: "account:#{source.external.id}", source_policy_version: source.policy.id, **attributes)
    end

    def retained_account_batch(source, account, stream:)
      account.update!(status: "disabled")
      binding = Provider::AccountData::GenerationAccounts.new(source.connection, resource: stream).capture_one(source.external)
      assert_equal "retained", binding.fetch("publication")
      assert_nil binding.fetch("source_policy_version")
      account_batch(source, stream: stream, source_policy_version: nil, source_binding: binding)
    end

    def observation(source, batch:, account:, kind: "transaction")
      SourceRecord.create!(family: account.family, account: account, external_account: source.external,
        ingestion_batch: batch, kind: kind, external_id: SecureRandom.uuid)
    end

    def statement_header(account)
      AccountStatement.new(family: account.family, account: account, filename: "private-statement.csv", byte_size: 10,
        content_type: "text/csv", checksum: SecureRandom.hex(16)).tap { |statement| statement.save!(validate: false) }
    end

    def calculation_input(account, source, batch)
      sync = account.syncs.create!(parent: batch.sync)
      payload = { "version" => 1, "family_id" => account.family_id, "account_id" => account.id,
        "provider_connection_id" => source.connection.id, "provider_sync_id" => batch.sync_id,
        "external_account_id" => source.external.id, "account_provider_id" => source.link.id,
        "source_batch_id" => batch.id, "inventory_batch_id" => batch.id, "source_policy_version" => source.policy.id,
        "account_provider_revision" => source.link.lock_version, "writer_epoch" => source.connection.writer_epoch,
        "observed_on" => Date.current.iso8601, "statement_sha256" => "a" * 64, "equity_payload_sha256" => "b" * 64 }
      # A valid typed captured handoff is enough for provisional ownership
      # discovery. Resolving/accepting its financial payload is a separate phase.
      Account::SyncInput.create!(account: account, family: account.family, sync: sync, provider_sync: batch.sync,
        source_batch: batch, resource: "historical_balances", kind: "ibkr_equity", payload: payload,
        payload_digest: Ingestion::HistoricalBalances.fingerprint(payload))
    end

    def proof_ids(result, kind)
      result.proof.fetch(kind).map { |row| row.fetch("id") }
    end

    def with_limit(name, value)
      previous = Sources.const_get(name)
      Sources.send(:remove_const, name)
      Sources.const_set(name, value)
      yield
    ensure
      Sources.send(:remove_const, name)
      Sources.const_set(name, previous)
    end

    def assert_deep_frozen(value)
      assert value.frozen?
      case value
      when Hash then value.each { |key, child| assert_deep_frozen(key); assert_deep_frozen(child) }
      when Array then value.each { |child| assert_deep_frozen(child) }
      end
    end
end

class Account::Destruction::SourcesRetainedTest < ActiveSupport::TestCase
  include RetainedAccountIndexTestHelper, IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Sources = Account::Destruction::Sources

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "verified historical account binding survives deletion of its live provider link" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      context.link.destroy!
      IngestionBatch.any_instance.expects(:payload).never

      result = Sources.capture(account: context.account)

      assert_equal [ context.control.provider_connection_id ], result.connection_ids
      assert_equal [ context.external.id ], result.external_ids
      assert_includes result.control_ids, context.control.id
      assert_includes result.mapping_ids, context.mapping.id
      assert_includes result.legacy_items, [ "UpItem", context.item.id ]
      assert_includes result.legacy_accounts, [ "UpAccount", context.source.id, context.item.id ]
      assert_equal [ receipt.id ], result.proof.fetch("retained_bindings").map { |row| row.fetch("id") }
      assert context.control.reload.shadow?
      assert context.control.provider_connection.disabled?
    end
  end

  test "unindexed retained chunks block even a currently unlinked financial account" do
    with_retained_account_copy do |context|
      retained_receipt(context).delete
      context.link.destroy!

      assert_raises(Sources::Incomplete) { Sources.capture(account: context.account) }

      assert context.control.provider_connection.ingestion_batches.exists?(stream: "legacy_snapshot")
      assert_empty ProviderMigrationAccountBinding.where(provider_migration_mapping_id: context.mapping.id)
    end
  end

  test "published legacy identity evidence retains its exact bootstrap batch and source owner" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_retained-ownership")
      Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      evidence = EntrySource.find_by!(entry_identity: entry.id, bootstrap_external_account: context.external)
      bootstrap_id = evidence.bootstrap_batch_id
      assert bootstrap_id.present?

      result = Sources.capture(account: context.account)

      assert_includes result.connection_ids, context.control.provider_connection_id
      assert_includes result.mapping_ids, context.mapping.id
      assert_includes result.proof.fetch("entry_sources").map { |row| row.fetch("id") }, evidence.id
      assert_includes result.proof.fetch("batches").map { |row| row.fetch("id") }, bootstrap_id
      assert_equal entry.id, evidence.reload.entry_identity
      assert context.control.reload.quiescing?
    end
  end
end
