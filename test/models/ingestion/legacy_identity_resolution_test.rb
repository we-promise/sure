require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::LegacyIdentityResolutionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Resolver = Ingestion::MappedEntryResolver
  Evidence = Ingestion::LegacyIdentityEvidence
  Fence = Provider::AccountData::LegacyWriterFence

  test "signed migration evidence resolves a protected legacy UUID without a provider Sync" do
    with_bootstrap(legacy_column: true, protected: true) do |external, entry, observations, batch|
      before = [ entry.attributes, entry.transaction.attributes ]

      result = resolve(external, observations.fetch("booked"))

      assert result.resolved?
      assert_equal entry.id, result.entry_identity
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_nil entry.external_id
      assert_nil entry.source
      assert_equal "booked", entry.plaid_id
      assert_equal "migration", batch.origin_kind
      assert_nil batch.sync_id
      assert_empty external.provider_connection.syncs
      assert external.provider_connection.disabled?
    end
  end

  test "an archive-only pending alias resolves without exposing a writable posting" do
    with_bootstrap do |external, entry, observations, _batch|
      before = [ entry.attributes, entry.transaction.attributes ]

      result = resolve(external, observations.fetch("pending-archive"))

      assert result.retired_alias?
      assert_nil result.entry
      assert_equal entry.id, result.entry_identity
      assert_equal "booked", result.current_external_id
      assert_nil entry.transaction.extra["auto_claimed_pending_ids"]
      assert_nil entry.transaction.extra.dig("plaid", "pending_transaction_id")
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "legacy-column postings also retain archive-only aliases without backfilling columns" do
    with_bootstrap(legacy_column: true) do |external, entry, observations, _batch|
      result = resolve(external, observations.fetch("pending-archive"))
      assert result.retired_alias?
      assert_equal "booked", result.current_external_id
      assert_nil entry.reload.source
      assert_nil entry.external_id
    end
  end

  test "native updates advance observations without invalidating the original financial proof" do
    with_bootstrap do |external, entry, observations, bootstrap_batch|
      current = observations.fetch("booked")
      original_id = entry.id

      apply(external, transaction_page("booked", amount: BigDecimal("45.67")))

      assert_equal original_id, entry.reload.id
      assert_equal BigDecimal("45.67"), entry.amount
      assert_equal "provider", current.reload.ingestion_batch.origin_kind
      assert_equal bootstrap_batch.id, current.entry_source.bootstrap_batch_id
      assert resolve(external, current).resolved?
      assert resolve(external, observations.fetch("pending-archive")).retired_alias?
      entry.update!(name: "My later correction", user_modified: true)
      assert resolve(external, current).resolved?
      assert_equal "My later correction", entry.reload.name
    end
  end

  test "replaying an archive-only pending alias does not change the booked posting" do
    with_bootstrap do |external, entry, observations, _batch|
      before = [ entry.attributes, entry.transaction.attributes ]
      assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count" ] do
        apply(external, transaction_page("pending-archive", amount: BigDecimal("999"), pending: true))
      end
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert resolve(external, observations.fetch("pending-archive")).retired_alias?
    end
  end

  test "withdrawing only a retired alias advances its evidence and leaves financial fields intact" do
    with_bootstrap do |external, entry, observations, bootstrap_batch|
      before = [ entry.attributes, entry.transaction.attributes ]

      apply(external, removal_page("pending-archive"))

      old = observations.fetch("pending-archive").reload
      assert old.withdrawn?
      assert_equal "provider", old.ingestion_batch.origin_kind
      assert_equal bootstrap_batch.id, old.entry_source.bootstrap_batch_id
      assert resolve(external, old).retired_alias?
      assert_not observations.fetch("booked").reload.withdrawn?
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "retired aliases do not prevent removal of their current unprotected posting" do
    [ [ "booked" ], %w[booked pending-archive], %w[pending-archive booked] ].each do |ids|
      with_bootstrap do |external, entry, observations, _batch|
        original_id = entry.id
        original_evidence = observations.transform_values do |observation|
          observation.entry_sources.sole.attributes.slice("entry_identity", "bootstrap_batch_id", "bootstrap_external_account_id", "bootstrap_identity_role", "bootstrap_entryable_type")
        end
        apply(external, removal_page(*ids))

        assert_not Entry.exists?(original_id), ids.inspect
        observations.each do |identity, observation|
          mapping = observation.entry_sources.sole
          assert_equal original_id, mapping.entry_identity
          assert_nil mapping.entry_id
          assert_not mapping.active?
          assert_equal original_evidence.fetch(identity), mapping.attributes.slice(*original_evidence.fetch(identity).keys)
        end
        assert_no_difference [ "Entry.count", "EntrySource.count", "SourceRecord.count" ] do
          apply(external, removal_page(*ids))
        end
        assert_raises(Resolver::Conflict) { resolve(external, observations.fetch("pending-archive")) }
      end
    end
  end

  test "retained bootstrap payload and origin cannot be changed or applied state rewound" do
    with_bootstrap do |external, entry, observations, batch|
      before = batch.reload.attributes
      changes = [
        [ { payload: { "format" => "changed-evidence" } }, "capture is immutable" ],
        [ { origin_kind: "provider" }, "capture is immutable" ],
        [ { status: "captured", applied_at: nil }, "publication is immutable" ]
      ]
      changes.each do |attributes, message|
        error = assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) do
            IngestionBatch.where(id: batch.id).update_all(attributes)
          end
        end
        assert_includes error.message, "Financial identity bootstrap #{message}"
        assert_equal before, batch.reload.attributes
      end

      assert_equal entry.id, resolve(external, observations.fetch("booked")).entry_identity
      assert resolve(external, observations.fetch("pending-archive")).retired_alias?
    end
  end

  test "an explicit bootstrap alias cannot suppress a now-current or foreign-source identity" do
    with_bootstrap do |external, entry, observations, _batch|
      alias_observation = observations.fetch("pending-archive")
      entry.update!(external_id: "pending-archive")
      assert_raises(Resolver::Conflict) { resolve(external, alias_observation) }
      entry.update!(external_id: "booked", source: "up")
      assert_raises(Resolver::Conflict) { resolve(external, alias_observation) }
    end
  end

  test "a current activity cannot adopt a different financial type than its signed bootstrap proof" do
    with_bootstrap(activity: true) do |external, entry, observations, _batch|
      observation = observations.fetch("booked")
      mapping = observation.entry_source
      assert_equal "activity", observation.kind
      assert_equal "Transaction", mapping.bootstrap_entryable_type
      original_transaction = entry.transaction
      begin
        replacement = Trade.create!(security: securities(:aapl), qty: BigDecimal("1"), price: BigDecimal("12.34"), currency: "USD")
        entry.update!(entryable: replacement)

        # The incoming activity now also requests Trade. Only the permanent
        # signed type prevents this retyped UUID from becoming a valid mapping.
        assert_raises(Resolver::Conflict) do
          Resolver.new(external_account: external, account: entry.account, definition: Provider::AccountData::Plaid.definition)
            .resolve(source_record: observation, kind: "activity", external_id: "booked", entryable_type: "Trade")
        end

        assert_equal "Transaction", mapping.reload.bootstrap_entryable_type
        assert_equal entry.id, mapping.entry_identity
        assert_equal replacement.id, entry.reload.entryable_id
      ensure
        original_transaction.delete # Reassignment leaves the original test row unattached.
      end
    end
  end

  test "bootstrap identity roles cannot be rewritten after a native batch replaces the observation" do
    with_bootstrap do |external, entry, observations, _batch|
      apply(external, transaction_page("booked"))
      mapping = observations.fetch("booked").reload.entry_source
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) do
          EntrySource.where(id: mapping.id).update_all(bootstrap_identity_role: "retired_alias")
        end
      end

      assert_equal "current", mapping.reload.bootstrap_identity_role
      assert resolve(external, observations.fetch("booked")).resolved?
      assert entry.reload.persisted?
    end
  end

  test "an ordinary legacy row archive cannot masquerade as posting identity evidence" do
    with_bootstrap do |external, entry, observations, _batch|
      snapshot = external.provider_connection.ingestion_batches.find_by!(stream: "legacy_snapshot", external_account: external)
      observation = observations.fetch("booked")
      SourceRecord.where(id: observation.id).update_all(ingestion_batch_id: snapshot.id)

      assert_raises(Resolver::Conflict) { resolve(external, observation) }
      assert entry.reload.persisted?
    end
  end

  test "migration observations cannot fall through when their permanent posting proof is missing" do
    with_bootstrap do |external, entry, observations, _batch|
      current = observations.fetch("booked")
      mapping = current.entry_source
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) do
          EntrySource.where(id: mapping.id).update_all(bootstrap_batch_id: nil, bootstrap_external_account_id: nil,
            bootstrap_identity_role: nil, bootstrap_entryable_type: nil)
        end
      end
      assert resolve(external, current).resolved?

      EntrySource.where(id: mapping.id).delete_all
      assert_raises(Resolver::Conflict) { resolve(external, current) }
      assert entry.reload.persisted?
    end
  end

  test "sealing requires both the held legacy permit and a current source policy" do
    with_bootstrap do |external, entry, _observations, batch|
      control = external.provider_connection.provider_migration_control
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
      plan = batch.payload.fetch("plan")
      before = [ entry.attributes, entry.transaction.attributes ]

      assert_raises(Evidence::InvalidEvidence) do
        ApplicationRecord.transaction { Evidence.seal(plan: plan, control: control, mapping: mapping) }
      end
      Account::SourcePolicy.active.where(account: entry.account, resource: "transactions").update_all(active: false)
      assert_raises(Provider::AccountData::StaleWriter) do
        Fence.with_exclusive(PlaidItem.find(control.legacy_id)) do
          control.with_lock { Evidence.seal(plan: plan, control: control, mapping: mapping) }
        end
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert external.provider_connection.disabled?
      assert control.reload.quiescing?
    end
  end

  test "sealing backs off from an in-flight financial edit and retries after its row lock is released" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_bootstrap do |external, entry, _observations, batch|
      control = external.provider_connection.provider_migration_control
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
      plan = batch.payload.fetch("plan")
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Entry.transaction do
            # Manual pending merges and ordinary edits can hold an Entry row
            # without first taking the bootstrap's financial Account lock.
            Entry.lock.find(entry.id)
            ready << true
            release.pop
          end
        end
      end
      begin
        Timeout.timeout(5) { ready.pop }
        assert_no_difference [ "SourceRecord.count", "EntrySource.count", "IngestionBatch.count" ] do
          error = assert_raises(Evidence::InvalidEvidence) do
            Timeout.timeout(5) do
              Fence.with_exclusive(PlaidItem.find(control.legacy_id)) do
                control.with_lock { Evidence.seal(plan: plan, control: control, mapping: mapping) }
              end
            end
          end
          assert_match(/retry/i, error.message)
        end
      ensure
        release << true
        begin
          Timeout.timeout(5) { worker.value }
        ensure
          worker.kill if worker.alive?
          worker.join
        end
      end

      payload = Fence.with_exclusive(PlaidItem.find(control.legacy_id)) do
        control.with_lock { Evidence.seal(plan: plan, control: control, mapping: mapping) }
      end
      assert_equal Evidence::FORMAT, payload.fetch("format")
      assert_equal entry.id, payload.fetch("plan").fetch("rows").sole.fetch("entry_id")
      assert control.reload.quiescing?
      assert external.provider_connection.disabled?
    end
  end

  private
    def with_bootstrap(legacy_column: false, protected: false, activity: false)
      with_provider_encryption do
        family = families(:dylan_family)
        item = PlaidItem.create!(family: family, name: "Identity bootstrap test", access_token: "private-test-token", plaid_id: SecureRandom.uuid, plaid_region: "us")
        account = family.accounts.create!(name: "Identity bootstrap account", balance: 100, currency: "USD", accountable: Depository.new, status: "active")
        source = item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Source account", currency: "USD", plaid_type: "depository", current_balance: 100)
        link = AccountProvider.create!(account: account, provider: source)
        entry = account.entries.create!(name: "Original posting", date: Date.current, amount: BigDecimal("12.34"), currency: "USD",
          source: legacy_column ? nil : "plaid", external_id: legacy_column ? nil : "booked", plaid_id: legacy_column ? "booked" : nil,
          user_modified: protected, import_locked: protected, entryable: Transaction.new(extra: { "plaid" => { "pending" => false } }))
        if activity
          source.update!(raw_transactions_payload: {}, raw_holdings_payload: { "transactions" => [ {
            "account_id" => source.plaid_id, "investment_transaction_id" => "booked", "type" => "cash"
          } ] })
        else
          source.update!(raw_transactions_payload: { "added" => [ { "account_id" => source.plaid_id,
            "transaction_id" => "booked", "pending" => false, "pending_transaction_id" => "pending-archive" } ] })
        end
        begin
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "plaid", legacy_item_id: item.id)
          5.times do
            break if copier.run_quiesced.high_water_mark["phase"] == "verified"
          end
          control = copier.control.reload
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: activity ? "activities" : "transactions")
          page = Provider::AccountData::Plaid::IdentityBootstrapPlan.new(mapping: mapping, family: family).page
          assert page.ready?
          row = page.document.fetch("rows").sole
          observations, batch = nil, nil
          Fence.with_exclusive(item) do
            control.with_lock do
              control.provider_connection.with_lock do
                payload = Evidence.seal(plan: page.document, control: control, mapping: mapping)
                batch = control.provider_connection.ingestion_batches.create!(family: family, external_account: external,
                  origin_kind: "migration", stream: "legacy_financial_identities", scope_key: "account:#{external.id}",
                  idempotency_key: SecureRandom.uuid, mode: "unknown", complete: false, payload: payload)
                observations = [ row.fetch("external_id"), *row.fetch("pending_aliases") ].to_h do |id|
                  identity_role = id == row.fetch("external_id") ? "current" : "retired_alias"
                  observation = SourceRecord.create!(family: family, account: account, external_account: external,
                    ingestion_batch: batch, kind: row.fetch("kind"), external_id: id, input_external_id: id,
                    input_occurrence: 0, pending: identity_role == "current" && row.fetch("pending"))
                  observation.create_entry_source!(entry: entry, account: account, family: family, role: "posting",
                    match_method: row.fetch("match_method"), bootstrap_batch: batch, bootstrap_external_account: external,
                    bootstrap_identity_role: identity_role)
                  [ id, observation ]
                end
                batch.update!(status: "applied", applied_at: Time.current)
              end
            end
          end
          yield external, entry, observations, batch
        ensure
          cleanup(item, account)
        end
      end
    end

    def cleanup(item, account)
      control = ProviderMigrationControl.find_by(legacy_type: "PlaidItem", legacy_id: item.id)
      connection = control&.provider_connection
      if connection
        observations = SourceRecord.where(external_account_id: connection.external_accounts.select(:id))
        EntrySource.where(source_record_id: observations.select(:id)).delete_all
        observations.delete_all
        connection.provider_sync_checkpoints.delete_all
        ProviderMigrationAccountBinding.where(family_id: control.family_id,
          provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all
        connection.ingestion_batches.delete_all
      end
      Account::SourcePolicy.where(account_id: account.id).delete_all
      AccountProvider.where(account_id: account.id).delete_all
      control&.provider_migration_mappings&.delete_all
      control&.delete
      connection&.destroy!
      account.reload.destroy!
      item.plaid_accounts.delete_all
      item.delete # Cleanup must not invoke the remote Plaid item-removal callback.
    end

    def resolve(external, observation)
      Resolver.new(external_account: external, account: external.current_account, definition: Provider::AccountData::Plaid.definition)
        .resolve(source_record: observation, kind: observation.kind, external_id: observation.external_id, entryable_type: "Transaction")
    end

    def transaction_page(id, amount: BigDecimal("12.34"), pending: false)
      Provider::AccountData::Page.new(records: [ Ingestion::Record.transaction(external_id: id, date: Date.current,
        amount: amount, currency: "USD", name: "Native observation", pending: pending) ], complete: true, mode: "delta")
    end

    def removal_page(*ids)
      Provider::AccountData::Page.new(records: [], removed_ids: ids, complete: true, mode: "delta", coverage: { removal_policy: "exact_external_id" })
    end

    def apply(external, page)
      # Exercise the writer contract without enabling the draft integration in
      # production or allowing this fixture to construct a network client.
      Provider::AccountData::Registry.stubs(:fetch).with("plaid").returns(Provider::AccountData::Plaid)
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "transactions")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
      IngestionBatch.transaction { Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page) }
    ensure
      Provider::AccountData::Registry.unstub(:fetch)
    end
end
