require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::MigrationRetirementTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Retirement = Provider::AccountData::MigrationRetirement

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
    Provider::AccountData::Brex.stubs(:native_ready?).returns(true)
    [ Provider::Up, Provider::Mercury, Provider::Brex ].each { |provider| provider.expects(:new).never }
  end
  teardown { clear_enqueued_jobs }

  %w[up mercury brex].each do |provider_key|
    test "#{provider_key} retirement preserves native financial and source evidence and replays without a live permit" do
      with_source(provider_key: provider_key) do |context|
        before = retained_state(context)
        mappings = context.control.provider_migration_mappings.order(:id).map { |mapping| mapping.attributes.except("retained_owner", "updated_at") }
        result = nil

        queries = capture_sql_queries { result = command(context).call }

        refute result.replayed
        assert_equal context.control.id, result.control_id
        assert_equal context.control.provider_connection_id, result.connection_id
        refute context.item.class.exists?(context.item.id)
        refute context.source.class.exists?(context.source.id)
        assert context.control.reload.retired?
        assert_equal before, retained_state(context)
        assert_equal mappings, context.control.provider_migration_mappings.order(:id).map { |mapping| mapping.attributes.except("retained_owner", "updated_at") }
        assert context.control.provider_migration_mappings.all? { |mapping| mapping.retained_owner.present? }
        assert_no_financial_sql(queries)
        receipt = context.control.audit_results.fetch("native_retirement")
        refute_includes receipt.to_json, "private-retirement-token"
        assert receipt.fetch("signature").is_a?(Hash)
        Account::SourcePolicy.where(account: context.account).each do |policy|
          assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
        end

        Provider::AccountData::LegacyWriterFence.expects(:with_exclusive).never
        replay = command(context).call
        assert replay.replayed
        assert_equal receipt, context.control.reload.audit_results.fetch("native_retirement")
        assert_equal before, retained_state(context)
      end
    end
  end

  test "a final receipt failure restores source rows and every newly captured witness" do
    with_source do |context|
      before = retained_state(context)
      audit = context.control.reload.audit_results.deep_dup
      fail_retirement = -> { raise IOError, "retirement commit fault" if id == context.control.id && retired? }
      ProviderMigrationControl.set_callback(:update, :after, fail_retirement)
      begin
        assert_raises(IOError) { command(context).call }
      ensure
        ProviderMigrationControl.skip_callback(:update, :after, fail_retirement)
      end

      assert context.item.class.exists?(context.item.id)
      assert context.source.class.exists?(context.source.id)
      assert context.control.reload.active?
      assert_equal audit, context.control.audit_results
      assert context.control.provider_migration_mappings.all? { |mapping| mapping.retained_owner.nil? }
      assert_equal before, retained_state(context)
      refute command(context).call.replayed
    end
  end

  test "legacy cache and credential drift refuse removal without replacing the archive" do
    [ :cache, :credential ].each do |change|
      with_source do |context|
        if change == :cache
          context.source.update_columns(raw_transactions_payload: [ { "id" => "uncaptured" } ])
        else
          context.item.update_columns(access_token: "different-private-token")
        end
        before = retained_state(context)

        error = assert_raises(Retirement::Conflict) { command(context).call }

        refute_includes error.message, "different-private-token"
        assert_live(context)
        assert_equal before, retained_state(context)
      end
    end
  end

  test "an unmapped legacy child prevents deleting the item" do
    with_source do |context|
      UpAccount.insert_all!([ { id: SecureRandom.uuid, up_item_id: context.item.id, account_id: "uncopied",
        name: "Uncopied source", currency: "USD", created_at: Time.current, updated_at: Time.current } ])
      before = UpAccount.where(up_item_id: context.item.id).order(:id).pluck(:id)

      assert_raises(Retirement::Conflict) { command(context).call }

      assert_live(context)
      assert_equal before, UpAccount.where(up_item_id: context.item.id).order(:id).pluck(:id)
    end
  end

  test "unfinished legacy or native work refuses while terminal original Syncs are preserved" do
    [ :item, :source, :connection ].each do |owner|
      with_source do |context|
        syncable = owner == :connection ? context.control.provider_connection : context.public_send(owner)
        pending = Sync.create!(syncable: syncable, status: "pending")
        begin
          assert_raises(Provider::AccountData::StaleWriter, Retirement::Busy) { command(context).call }
          assert_live(context)
          pending.update!(status: "failed", completed_at: Time.current)
          command(context).call
          assert_equal "failed", pending.reload.status
        ensure
          pending.delete
        end
      end
    end
  end

  test "legitimate native unlink does not rewrite or reassign the original archived financial owner" do
    with_source do |context|
      original_archive = context.control.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text"))
      assert Account::Unlink.new(account: context.account, user: context.account.owner).call
      before = context.account.reload.attributes

      command(context).call

      assert_equal before, context.account.reload.attributes
      refute AccountProvider.exists?(context.link.id)
      assert_nil context.external.reload.current_account
      assert_equal original_archive, context.control.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text"))
      retained = Provider::AccountData::RetainedRow.new(connection: context.control.provider_connection, provider_key: "up").account(context.external)
      assert_equal context.account.id, retained.archive.fetch("account_binding").fetch("financial_context").fetch("id")
    end
  end

  test "an altered retirement receipt cannot authorize replay" do
    with_source do |context|
      command(context).call
      audit = context.control.reload.audit_results.deep_dup
      changed = audit.deep_dup
      changed.fetch("native_retirement")["retired_at"] = "2026-01-01T00:00:00Z"
      context.control.update!(audit_results: changed)
      begin
        assert_raises(Retirement::Conflict) { command(context).call }
      ensure
        context.control.update!(audit_results: audit)
      end
      assert command(context).call.replayed
    end
  end

  test "completed retirement replay preserves later pending native work" do
    with_source do |context|
      command(context).call
      pending = context.control.provider_connection.syncs.create!(status: "pending")
      original = pending.reload.attributes

      assert_no_enqueued_jobs { assert command(context).call.replayed }

      assert_equal original, pending.reload.attributes
    ensure
      pending&.delete
    end
  end

  test "a damaged retained archive refuses replay after physical retirement" do
    with_source do |context|
      command(context).call
      batch = context.control.provider_connection.ingestion_batches.find_by!(stream: "legacy_snapshot", external_account_id: context.external.id, sequence: 0)
      original = IngestionBatch.where(id: batch.id).pick(Arel.sql("payload::text"))
      IngestionBatch.where(id: batch.id).update_all(payload: { "damaged" => true })
      begin
        assert_raises(Retirement::Conflict) { command(context).call }
      ensure
        IngestionBatch.where(id: batch.id).update_all([ "payload = ?", original ])
      end
      assert command(context).call.replayed
    end
  end

  test "readiness family scope and an enclosing transaction cannot be bypassed" do
    with_source(provider_key: "mercury") do |context|
      Provider::AccountData::Mercury.unstub(:native_ready?)
      assert_raises(Provider::AccountData::UnsupportedCapability) { command(context).call }
      Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
      other = Family.create!(name: "Other retirement family")
      begin
        assert_raises(Retirement::Conflict) do
          Retirement.new(provider_key: "mercury", legacy_item_id: context.item.id, family: other).call
        end
        ApplicationRecord.transaction(requires_new: true) do
          assert_raises(ArgumentError) { command(context).call }
        end
        assert_live(context)
      ensure
        other.destroy!
      end
    end
  end

  private
    def command(context)
      Retirement.new(provider_key: context.control.provider_key, legacy_item_id: context.item.id, family: context.family)
    end

    def assert_live(context)
      assert context.item.class.exists?(context.item.id)
      assert context.source.class.exists?(context.source.id)
      assert context.control.reload.active?
      assert_nil context.control.audit_results["native_retirement"]
    end

    def retained_state(context)
      connection = context.control.provider_connection
      { financial: identity_financial_snapshot(context),
        links: AccountProvider.where(account: context.account).order(:id).map(&:attributes),
        policies: Account::SourcePolicy.where(account: context.account).order(:id).map(&:attributes),
        external: context.external.reload.attributes,
        connection: connection.reload.attributes,
        batches: connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text")),
        checkpoints: connection.provider_sync_checkpoints.order(:id).pluck(:id, Arel.sql("state::text")),
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        entry_sources: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes),
        syncs: Sync.where(syncable_type: context.item.class.name, syncable_id: context.item.id)
          .or(Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id)).order(:id).map(&:attributes) }
    end

    def with_source(provider_key: "up")
      with_provider_encryption do
        family = Family.create!(name: "Retirement test family")
        owner = family.users.create!(email: "retirement-#{SecureRandom.uuid}@example.com", password: "retirement-password", role: "admin")
        item_class = { "up" => UpItem, "mercury" => MercuryItem, "brex" => BrexItem }.fetch(provider_key)
        credential = provider_key == "up" ? :access_token : :token
        item = item_class.create!(family: family, name: "Original connection", credential => "private-retirement-token")
        account = family.accounts.create!(owner: owner, name: "Original account", currency: "USD", balance: 100,
          accountable: Depository.new, status: "active")
        source_attributes = { account_id: "original-remote", name: "Checking", currency: "USD", current_balance: 100, raw_transactions_payload: [] }
        source_attributes[:account_kind] = "cash" if provider_key == "brex"
        source = item.public_send("#{provider_key}_accounts").create!(source_attributes)
        if provider_key == "brex"
          raw = { "id" => source.account_id, "name" => source.name, "account_kind" => "cash", "status" => "ACTIVE",
            "current_balance" => { "amount" => 10_000, "currency" => "USD" },
            "available_balance" => { "amount" => 10_000, "currency" => "USD" } }
          item.upsert_brex_snapshot!("accounts" => [ raw ], "cash_accounts" => [ raw.deep_dup ], "card_accounts" => [])
          source.upsert_brex_snapshot!(raw)
        end
        link = AccountProvider.create!(account: account, provider: source)
        if provider_key == "up"
          account.entries.create!(name: "Protected original", amount: 10, date: Date.current, currency: "USD",
            source: "up", external_id: "up_retirement-original", import_locked: true, user_modified: true,
            entryable: Transaction.new(extra: { "up" => { "pending" => false } }))
        end
        item.syncs.create!(status: "completed", completed_at: Time.current)
        copier = Provider::AccountData::MigrationCopier.new(provider_key: provider_key, legacy_item_id: item.id, batch_size: 1)
        control = nil
        20.times do
          control = copier.run_quiesced.reload
          break if control.high_water_mark["phase"] == "verified"
        end
        assert_equal "verified", control.high_water_mark["phase"]
        prepared = nil
        150.times do
          prepared = Provider::AccountData::MigrationPreparation.new(provider_key: provider_key, legacy_item_id: item.id, family: family, page_size: 1).run
          break if prepared.awaiting_acceptance?
        end
        assert prepared.awaiting_acceptance?
        cutover = Provider::AccountData::MigrationCutover.new(provider_key: provider_key, legacy_item_id: item.id, family: family, page_size: 1).call
        # No provider request or historical coverage is claimed by this fixture.
        Sync.find(cutover.sync_id).update!(status: "failed", completed_at: Time.current)
        control.reload
        external = control.provider_connection.external_accounts.sole
        mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
        yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
          link: link.reload, copier: copier, control: control, mapping: mapping, external: external)
      ensure
        if item && account
          connection_id = ProviderMigrationControl.find_by(legacy_type: item.class.name, legacy_id: item.id)&.provider_connection_id
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection_id).delete_all if connection_id
          Sync.where(syncable_type: item.class.name, syncable_id: item.id).delete_all
          cleanup_identity_source(item, account)
        end
        owner&.destroy!
        family&.destroy!
        clear_enqueued_jobs
      end
    end
end
