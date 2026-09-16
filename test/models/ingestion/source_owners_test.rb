require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::SourceOwnersTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Owners = Ingestion::SourceOwners
  Source = Data.define(:account, :link, :policy, :legacy, :item, :external, :connection)

  test "a retained legacy policy still discovers its original item after both link and source account are deleted" do
    with_provider_encryption do
      source = legacy_source
      original = source.policy.reload.attributes
      detach(source)
      UpAccount.where(id: source.legacy.id).delete_all
      snapshot = nil

      queries = capture_sql_queries { snapshot = resolve(source) }

      assert_equal [ [ "UpItem", source.item.id ] ], snapshot.legacy_items
      assert_equal [ [ "UpAccount", source.legacy.id, source.item.id ] ], snapshot.legacy_accounts
      assert_empty snapshot.connection_ids
      assert_empty snapshot.external_ids
      assert_empty snapshot.proof.fetch("links")
      assert_equal [ source.policy.id ], snapshot.proof.fetch("retained_sources").map { |row| row.fetch("id") }
      missing = snapshot.proof.fetch("legacy_accounts").sole
      assert_equal true, missing.fetch("retained_missing")
      assert_nil missing.fetch("row_version")
      assert_nil missing.fetch("tuple_version")
      assert snapshot.frozen?
      assert snapshot.proof.fetch("retained_sources").frozen?
      assert snapshot.proof.fetch("retained_sources").sole.frozen?
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b|FOR (?:UPDATE|SHARE)|pg_.*advisory/i)
      assert_equal original.except("active", "updated_at", "required_account_provider_id"),
        source.policy.reload.attributes.except("active", "updated_at", "required_account_provider_id")
      assert_not_includes snapshot.proof.to_json, "private-retained-owner-token"
      assert_not_includes snapshot.proof.to_json, source.account.name
    end
  end

  test "a retained legacy tuple does not authorize inventing a missing original item" do
    with_provider_encryption do
      source = legacy_source
      detach(source)
      UpAccount.where(id: source.legacy.id).delete_all
      UpItem.where(id: source.item.id).delete_all

      assert_raises(Owners::InvalidGraph) { resolve(source) }

      assert source.policy.reload.persisted?
      assert_equal source.item.id, source.policy.source_binding.fetch("legacy_item_id")
    end
  end

  test "an existing legacy source moved to another item cannot override its captured parent" do
    with_provider_encryption do
      source = legacy_source
      detach(source)
      other = UpItem.create!(family: source.account.family, name: "Replacement parent", access_token: "private-replacement-token")
      UpAccount.where(id: source.legacy.id).update_all(up_item_id: other.id)

      assert_raises(Owners::InvalidGraph) { resolve(source) }

      assert_equal source.item.id, source.policy.reload.source_binding.fetch("legacy_item_id")
      assert_equal other.id, source.legacy.reload.up_item_id
    end
  end

  test "retained history cannot make a broken current provider link valid" do
    with_provider_encryption do
      source = legacy_source
      UpAccount.where(id: source.legacy.id).delete_all

      assert_raises(Owners::InvalidGraph) do
        Owners.capture(family_id: source.account.family_id,
          links: [ source.link.attributes.slice(*Owners::LINK_COLUMNS) ], direct_sources: [], external_ids: [],
          retained_sources: [ descriptor(source.policy) ])
      end

      assert AccountProvider.exists?(source.link.id)
      assert source.policy.reload.active?
    end
  end

  test "a detached native policy discovers its exact connection without a fictional legacy owner" do
    with_provider_encryption do
      source = native_source
      detach(source)
      snapshot = resolve(source)

      assert_equal [ source.connection.id ], snapshot.connection_ids
      assert_equal [ source.external.id ], snapshot.external_ids
      assert_empty snapshot.legacy_items
      assert_empty snapshot.legacy_accounts
      assert_empty snapshot.control_ids
      assert_empty snapshot.mapping_ids
      assert_empty snapshot.proof.fetch("links")
      assert_equal source.policy.source_binding, snapshot.proof.fetch("retained_sources").sole.fetch("source_binding")
      assert_not_includes snapshot.proof.to_json, "private-provider-token"
      assert source.policy.reload.valid?
    end
  end

  test "retained descriptors must match the persisted policy and exact family" do
    with_provider_encryption do
      source = native_source
      detach(source)
      request = descriptor(source.policy)
      [ { "external_account_id" => SecureRandom.uuid }, { "provider_connection_id" => SecureRandom.uuid },
        { "provider_key" => "plaid" }, { "family_id" => families(:empty).id } ].each do |change|
        assert_raises(Owners::InvalidGraph) do
          resolve(source, retained_sources: [ request.merge(binding: source.policy.source_binding.merge(change)) ])
        end
      end
      assert_raises(Owners::InvalidGraph) { resolve(source, family_id: families(:empty).id) }
      assert_raises(Owners::InvalidGraph) { resolve(source, retained_sources: [ request.merge(policy_id: SecureRandom.uuid) ]) }
      assert_raises(Owners::InvalidGraph) { resolve(source, retained_sources: [ request.except(:policy_id) ]) }
      assert_raises(Owners::InvalidGraph) { resolve(source, retained_sources: [ request, request.deep_dup ]) }
      assert_equal [ source.connection.id ], resolve(source).connection_ids
    end
  end

  test "a native source moved to another same-provider connection cannot rewrite the retained connection" do
    with_provider_encryption do
      source = native_source
      detach(source)
      replacement = create_provider_connection(family: source.account.family)
      source.external.update_columns(provider_connection_id: replacement.id)

      assert_raises(Owners::InvalidGraph) { resolve(source) }

      assert_equal source.connection.id, source.policy.reload.source_binding.fetch("provider_connection_id")
      assert_equal replacement.id, source.external.reload.provider_connection_id
    end
  end

  test "a descriptor for a deleted policy cannot act as retained source proof" do
    with_provider_encryption do
      source = native_source
      request = descriptor(source.policy)
      Account::SourcePolicy.where(id: source.policy.id).delete_all

      assert_raises(Owners::InvalidGraph) { resolve(source, retained_sources: [ request ]) }
      assert AccountProvider.exists?(source.link.id)
    end
  end

  test "retained proof budgets refuse oversized reads without changing the original policy" do
    with_provider_encryption do
      source = native_source
      detach(source)
      original = source.policy.reload.attributes

      with_limit(:MAX_RETAINED_BINDING_BYTES, 1) { assert_raises(Owners::TooLarge) { resolve(source) } }
      with_limit(:MAX_ROWS, 1) { assert_raises(Owners::TooLarge) { resolve(source) } }

      assert_equal original, source.policy.reload.attributes
      assert_equal [ source.connection.id ], resolve(source).connection_ids
    end
  end

  test "callers without retained policies preserve the existing proof shape" do
    with_provider_encryption do
      source = native_source
      snapshot = Owners.capture(family_id: source.account.family_id, links: [], direct_sources: [], external_ids: [],
        connection_ids: [ source.connection.id ])

      refute snapshot.proof.key?("retained_sources")
      assert_equal [ source.connection.id ], snapshot.connection_ids
    end
  end

  private

    def account
      families(:dylan_family).accounts.create!(name: "Retained owner account", currency: "USD", balance: 0, accountable: Depository.new)
    end

    def native_source
      financial = account
      connection = create_provider_connection(family: financial.family)
      external = create_external_account(connection)
      link = AccountProvider.create!(account: financial, external_account: external)
      policy = Account::SourcePolicy.select!(account: financial, account_provider: link, resource: "balances")
      Source.new(financial, link, policy, nil, nil, external, connection)
    end

    def legacy_source
      financial = account
      item = UpItem.create!(family: financial.family, name: "Retained legacy owner", access_token: "private-retained-owner-token")
      legacy = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", raw_transactions_payload: [])
      link = AccountProvider.create!(account: financial, family: financial.family, provider: legacy)
      policy = Account::SourcePolicy.select!(account: financial, account_provider: link, resource: "balances")
      Source.new(financial, link, policy, legacy, item, nil, nil)
    end

    def detach(source)
      Account::SourcePolicy.where(id: source.policy.id).update_all(active: false)
      source.link.destroy!
      source.policy.reload
    end

    def descriptor(policy)
      { policy_id: policy.id, binding: policy.source_binding.deep_dup }
    end

    def resolve(source, retained_sources: [ descriptor(source.policy) ], family_id: source.account.family_id)
      Owners.capture(family_id: family_id, links: [], direct_sources: [], external_ids: [], retained_sources: retained_sources)
    end

    def with_limit(name, value)
      previous = Owners.const_get(name)
      Owners.send(:remove_const, name)
      Owners.const_set(name, value)
      yield
    ensure
      Owners.send(:remove_const, name)
      Owners.const_set(name, previous)
    end
end

class Ingestion::CopiedSourceOwnersTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Provider::Up.expects(:new).never
  end

  teardown do
    clear_enqueued_jobs
  end

  test "retired copied dual sources retain exact owner proof and policy verification without live compatibility rows" do
    with_retired_source do |context|
      policies = Account::SourcePolicy.where(account: context.account).order(:id).to_a
      assert_equal %w[balances transactions], policies.map(&:resource).sort
      original = policies.map(&:attributes)
      snapshot = capture_current(context)

      assert_equal [ [ "UpItem", context.item.id ] ], snapshot.legacy_items
      assert_equal [ [ "UpAccount", context.source.id, context.item.id ] ], snapshot.legacy_accounts
      assert_equal [ context.control.provider_connection_id ], snapshot.connection_ids
      %w[legacy_items legacy_accounts].each do |kind|
        owner = snapshot.proof.fetch(kind).sole
        assert owner.fetch("retired_owner").present?
        refute owner.key?("retained_missing")
        assert_nil owner.fetch("row_version")
        assert_nil owner.fetch("tuple_version")
      end
      assert_not_includes snapshot.proof.to_json, "private-retired-source-token"
      policies.each { |policy| assert Account::SourcePolicy::Binding.verify_live!(policy: policy) }
      assert_equal original, policies.map { |policy| policy.reload.attributes }
      assert_equal context.source.id, policies.first.source_binding.fetch("legacy_account_id")
      assert_equal context.item.id, policies.first.source_binding.fetch("legacy_item_id")
      balance = policies.find { |policy| policy.resource == "balances" }
      Account::SourcePolicy.where(id: balance.id).update_all(active: false)
      replacement = Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "balances")
      assert_equal balance.revision + 1, replacement.revision
      assert_equal balance.source_binding, replacement.source_binding
      assert Account::SourcePolicy::Binding.verify_live!(policy: replacement)
    end
  end

  test "a native-only link can select policies after its originally unlinked compatibility source is retired" do
    with_retired_source(native_only: true) do |context|
      retained = Provider::AccountData::RetainedRow.new(connection: context.control.provider_connection, provider_key: "up").account(context.external)
      assert_nil Provider::AccountData::MigrationCopier.account_binding!(archive: retained.archive).fetch("financial_context")
      originals = retained_archive_bytes(context)
      link = AccountProvider.create!(account: context.account, external_account: context.external)

      policies = Account::SourcePolicy.select_many!(account: context.account, account_provider: link, resources: %w[balances transactions])

      policies.each do |policy|
        assert_nil policy.source_binding.fetch("legacy_account_id")
        assert_equal context.external.id, policy.source_binding.fetch("external_account_id")
        assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
      end
      assert_equal originals, retained_archive_bytes(context)
      assert_equal context.account.id, context.external.reload.current_account.id
    end
  end

  test "native unlink after compatibility retirement preserves financial data and original archives" do
    with_retired_source do |context|
      policy_rows = Account::SourcePolicy.where(account: context.account).order(:id).to_a
      bindings = policy_rows.to_h { |policy| [ policy.id, policy.source_binding ] }
      original_account = context.account.reload.attributes
      archives = retained_archive_bytes(context)
      mappings = context.control.provider_migration_mappings.order(:id).map(&:attributes)

      assert Account::Unlink.new(account: context.account, user: context.account.owner).call

      refute AccountProvider.exists?(context.link.id)
      assert_equal original_account, context.account.reload.attributes
      assert_equal archives, retained_archive_bytes(context)
      assert_equal mappings, context.control.provider_migration_mappings.order(:id).map(&:attributes)
      policy_rows.each do |policy|
        refute policy.reload.active?
        assert_equal bindings.fetch(policy.id), policy.source_binding
      end
      assert context.control.reload.retired?
      assert ExternalAccount.exists?(context.external.id)
      assert ProviderConnection.exists?(context.control.provider_connection_id)
    end
  end

  test "retired state without an authenticated owner disposition does not replace missing compatibility rows" do
    with_retired_source(capture: false) do |context|
      assert_raises(Ingestion::SourceOwners::DispositionRequired) { capture_current(context) }
      policy = Account::SourcePolicy.find_by!(account: context.account, resource: "balances")
      assert_raises(Account::SourcePolicy::Binding::Conflict) { Account::SourcePolicy::Binding.verify_live!(policy: policy) }
      assert AccountProvider.exists?(context.link.id)
      assert policy.reload.active?
    end
  end

  test "retired archives cannot override a present legacy account with a contradictory parent" do
    with_retired_source do |context|
      ApplicationRecord.transaction(requires_new: true) do
        replacement = UpItem.create!(family: context.family, name: "Different parent", access_token: "private-replacement-token")
        UpAccount.create!(id: context.source.id, up_item: replacement, account_id: context.source.account_id,
          name: "Contradictory source", currency: "USD", raw_transactions_payload: [])

        assert_raises(Ingestion::SourceOwners::InvalidGraph) { capture_current(context) }
        assert_equal replacement.id, UpAccount.find(context.source.id).up_item_id
        raise ActiveRecord::Rollback
      end
      assert capture_current(context).proof.fetch("legacy_accounts").sole.fetch("retired_owner")
    end
  end

  test "a changed retired archive cannot authorize source selection or unlink" do
    with_retired_source do |context|
      originals = retained_archive_bytes(context)
      batch = context.control.provider_connection.ingestion_batches.find_by!(stream: "legacy_snapshot",
        scope_key: "UpAccount:#{context.source.id}", sequence: 0)
      policy = Account::SourcePolicy.find_by!(account: context.account, resource: "balances")
      original_binding = policy.source_binding
      ApplicationRecord.transaction(requires_new: true) do
        IngestionBatch.where(id: batch.id).update_all(payload: batch.payload.merge("data" => Base64.strict_encode64("changed-archive")))

        assert_raises(Ingestion::SourceOwners::DispositionRequired) { capture_current(context) }
        assert_raises(Account::SourcePolicy::Binding::Conflict) { Account::SourcePolicy::Binding.verify_live!(policy: policy) }
        assert_raises(Provider::AccountData::LegacyWriterFence::OwnershipChanged) do
          Account::Unlink.new(account: context.account, user: context.account.owner).call
        end
        assert AccountProvider.exists?(context.link.id)
        assert policy.reload.active?
        assert_equal original_binding, policy.source_binding
        raise ActiveRecord::Rollback
      end

      assert_equal originals, retained_archive_bytes(context)
      assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
    end
  end

  test "retired owner resolution enforces one cumulative archive budget" do
    with_retired_source do |context|
      sizes = context.control.provider_migration_mappings.map do |mapping|
        Provider::AccountData::RetiredOwner.resolve!(mapping: mapping, family_id: context.family.id,
          max_bytes: Ingestion::SourceOwners::MAX_RETIRED_ARCHIVE_BYTES).bytes
      end
      assert_equal 2, sizes.size
      assert sizes.all?(&:positive?)
      original = retained_archive_bytes(context)
      limit = Ingestion::SourceOwners::MAX_RETIRED_ARCHIVE_BYTES
      begin
        Ingestion::SourceOwners.send(:remove_const, :MAX_RETIRED_ARCHIVE_BYTES)
        Ingestion::SourceOwners.const_set(:MAX_RETIRED_ARCHIVE_BYTES, sizes.sum - 1)
        assert_raises(Ingestion::SourceOwners::TooLarge) { capture_current(context) }
      ensure
        Ingestion::SourceOwners.send(:remove_const, :MAX_RETIRED_ARCHIVE_BYTES)
        Ingestion::SourceOwners.const_set(:MAX_RETIRED_ARCHIVE_BYTES, limit)
      end
      assert_equal original, retained_archive_bytes(context)
      assert capture_current(context)
    end
  end

  test "a copied retained source with a missing original item requires explicit disposition" do
    with_identity_source(quiesced: false) do |context|
      policy = Account::SourcePolicy.find_by!(account_id: context.account.id, resource: "transactions")
      Account::SourcePolicy.where(id: policy.id).update_all(active: false)
      context.link.destroy!
      UpAccount.where(id: context.source.id).delete_all
      UpItem.where(id: context.item.id).delete_all

      assert_raises(Ingestion::SourceOwners::DispositionRequired) do
        Ingestion::SourceOwners.capture(family_id: context.family.id, links: [], direct_sources: [], external_ids: [],
          retained_sources: [ { policy_id: policy.id, binding: policy.source_binding } ])
      end
      assert context.control.reload.shadow?
      assert policy.reload.persisted?
    end
  end

  test "legacy and dual revisions of the same link resolve together without replacing either original tuple" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = UpItem.create!(family: family, name: "Mixed retained revisions", access_token: "private-mixed-revision-token")
      account = family.accounts.create!(name: "Mixed source policy account", currency: "USD", balance: 0, accountable: Depository.new)
      begin
        legacy = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", raw_transactions_payload: [])
        link = AccountProvider.create!(account: account, family: family, provider: legacy)
        original = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1)
        control = nil
        15.times do
          control = copier.run.reload
          break if control.shadow?
        end
        assert control.shadow?
        external = control.provider_connection.external_accounts.sole
        Account::SourcePolicy.where(id: original.id).update_all(active: false)
        current = Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "balances")
        assert_equal 1, original.revision
        assert_equal 2, current.revision
        Account::SourcePolicy.where(id: [ original.id, current.id ]).update_all(active: false)
        link.destroy!
        requests = [ original, current ].map { |policy| { policy_id: policy.id, binding: policy.source_binding.deep_dup } }
        forward = Ingestion::SourceOwners.capture(family_id: family.id, links: [], direct_sources: [], external_ids: [], retained_sources: requests)
        reverse = Ingestion::SourceOwners.capture(family_id: family.id, links: [], direct_sources: [], external_ids: [], retained_sources: requests.reverse)

        assert_equal forward, reverse
        assert_equal [ [ "UpItem", item.id ] ], forward.legacy_items
        assert_equal [ [ "UpAccount", legacy.id, item.id ] ], forward.legacy_accounts
        assert_equal [ external.id ], forward.external_ids
        assert_equal [ control.provider_connection_id ], forward.connection_ids
        assert_equal [ control.id ], forward.control_ids
        rows = forward.proof.fetch("retained_sources").index_by { |row| row.fetch("id") }
        assert_equal [ original.id, current.id ].sort, rows.keys.sort
        assert_nil rows.fetch(original.id).fetch("source_binding").fetch("external_account_id")
        assert_equal external.id, rows.fetch(current.id).fetch("source_binding").fetch("external_account_id")
        assert_equal [ link.id ], rows.values.map { |row| row.fetch("account_provider_id") }.uniq
        assert_empty forward.proof.fetch("links")
      ensure
        cleanup_identity_source(item, account)
      end
    end
  end

  private
    def with_retired_source(native_only: false, capture: true)
      with_provider_encryption do
        family = Family.create!(name: "Retired source owners")
        owner = family.users.create!(email: "retired-source-#{SecureRandom.uuid}@example.com", password: "retired-password", role: "admin")
        item = UpItem.create!(family: family, name: "Retired Up", access_token: "private-retired-source-token")
        account = family.accounts.create!(owner: owner, name: "Original financial owner", currency: "USD", balance: 0,
          accountable: Depository.new, status: "active")
        source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Retained source", currency: "USD",
          current_balance: 0, raw_transactions_payload: [])
        link = AccountProvider.create!(account: account, provider: source) unless native_only
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1)
        control = nil
        20.times do
          control = copier.run_quiesced.reload
          break if control.high_water_mark["phase"] == "verified"
        end
        assert_equal "verified", control.high_water_mark["phase"]
        prepared = nil
        150.times do
          prepared = Provider::AccountData::MigrationPreparation.new(provider_key: "up", legacy_item_id: item.id, family: family, page_size: 1).run
          break if prepared.awaiting_acceptance?
        end
        assert prepared.awaiting_acceptance?
        result = Provider::AccountData::MigrationCutover.new(provider_key: "up", legacy_item_id: item.id, family: family, page_size: 1).call
        # This fixture never runs the queued provider job or claims coverage.
        Sync.find(result.sync_id).update!(status: "failed", completed_at: Time.current)
        control.reload
        Provider::AccountData::RetiredOwner.prepare!(control: control, family: family) if capture
        control.reload.update!(state: "retired")
        UpAccount.where(id: source.id).delete_all
        UpItem.where(id: item.id).delete_all
        external = control.provider_connection.external_accounts.sole
        mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
        yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
          link: link&.reload, copier: copier, control: control, mapping: mapping, external: external)
      ensure
        if item && account
          connection_id = ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)&.provider_connection_id
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection_id).delete_all if connection_id
          cleanup_identity_source(item, account)
        end
        owner&.destroy!
        family&.destroy!
        clear_enqueued_jobs
      end
    end

    def capture_current(context)
      Ingestion::SourceOwners.capture(family_id: context.family.id,
        links: [ context.link.reload.attributes.slice(*Ingestion::SourceOwners::LINK_COLUMNS) ], direct_sources: [], external_ids: [])
    end

    def retained_archive_bytes(context)
      context.control.provider_connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text"))
    end
end
