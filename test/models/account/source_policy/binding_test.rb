require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Account::SourcePolicy::BindingTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper

  Binding = Account::SourcePolicy::Binding
  Policy = Account::SourcePolicy
  Source = Data.define(:account, :link, :external, :connection, :legacy, :item)

  test "native selection captures an exact immutable source tuple and the original account identity" do
    with_provider_encryption do
      source = native_source
      captured = nil
      assert_difference "Account::IngestionIdentity.count", 1 do
        captured = Binding.capture!(account: source.account, account_provider: source.link)
      end

      assert_equal expected_binding(source), captured
      assert captured.frozen?
      assert captured.keys.all?(&:frozen?)
      assert captured.values.compact.all?(&:frozen?)
      assert_not_includes captured.to_json, "private-provider-token"
      assert_not_includes captured.to_json, source.account.name
      policy = select_policy(source)
      assert_equal captured, policy.source_binding
      assert Binding.validate!(policy.source_binding, policy: policy)
      assert_equal source.account.family_id, policy.account_identity.family_id
      assert_equal source.account.id, policy.account_identity.id
      assert_no_difference "Policy.count" do
        assert_equal policy.id, select_policy(source).id
      end
    end
  end

  test "pure legacy selection captures local source and item UUIDs without inventing a shared connection" do
    source = legacy_source
    captured = Binding.capture!(account: source.account, account_provider: source.link)
    policy = select_policy(source)

    assert_equal expected_binding(source), captured
    assert_equal captured, policy.source_binding
    assert_nil captured.fetch("external_account_id")
    assert_nil captured.fetch("provider_connection_id")
    assert_equal "UpAccount", captured.fetch("legacy_account_type")
    assert_equal source.legacy.id, captured.fetch("legacy_account_id")
    assert_equal "UpItem", captured.fetch("legacy_item_type")
    assert_equal source.item.id, captured.fetch("legacy_item_id")
    assert_not_includes captured.to_json, source.legacy.account_id
    assert_not_includes captured.to_json, "private-legacy-binding-token"
  end

  test "validation rejects missing extra foreign malformed and unregistered native binding fields" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      binding = policy.source_binding
      invalid = [ binding.except("capture_kind"), binding.merge("credential" => "forbidden"),
        binding.merge("family_id" => families(:empty).id), binding.merge("account_id" => SecureRandom.uuid),
        binding.merge("account_provider_id" => SecureRandom.uuid), binding.merge("capture_kind" => "reconstructed"),
        binding.merge("provider_key" => "unregistered-binding-provider"), binding.merge("external_account_id" => nil),
        binding.merge("external_account_id" => "not-a-uuid"),
        binding.merge("external_account_id" => nil, "provider_connection_id" => nil) ]

      invalid.each { |value| assert_raises(Binding::Conflict) { Binding.validate!(value, policy: policy) } }
      assert_equal binding, policy.reload.source_binding
    end
  end

  test "legacy binding validation rejects incomplete or contradictory source types" do
    source = legacy_source
    policy = select_policy(source)
    binding = policy.source_binding
    [ { "legacy_item_id" => nil }, { "legacy_account_type" => "Account" },
      { "legacy_item_type" => "PlaidItem" }, { "provider_key" => "plaid" } ].each do |change|
      assert_raises(Binding::Conflict) { Binding.validate!(binding.merge(change), policy: policy) }
    end
    assert_equal binding, policy.reload.source_binding
  end

  test "direct legacy policy insertion verifies the original parent type item and provider key" do
    with_provider_encryption do
      source = legacy_source
      policy = select_policy(source).reload
      other_item = UpItem.create!(family: source.account.family, name: "Unrelated same-family item", access_token: "private-wrong-parent-token")
      assert_nil source.link.reload.provider_key
      attributes = policy.attributes.except("required_account_provider_id", "source_external_account_id",
        "source_provider_connection_id", "source_provider_key").merge("id" => SecureRandom.uuid, "revision" => 2, "active" => false)

      [ { "legacy_item_id" => other_item.id }, { "legacy_item_type" => "PlaidItem" },
        { "provider_key" => "plaid" } ].each do |change|
        assert_database_failure do
          Policy.insert_all!([ attributes.merge("source_binding" => policy.source_binding.merge(change)) ])
        end
      end

      assert_equal [ policy.id ], Policy.where(account_id: source.account.id).pluck(:id)
      assert_equal source.item.id, policy.reload.source_binding.fetch("legacy_item_id")
    end
  end

  test "capture refuses another account or family and rolls back a missing source owner" do
    source = legacy_source
    other = financial_account(family: families(:empty))
    assert_raises(Binding::Conflict) { Binding.capture!(account: other, account_provider: source.link) }
    forged = Account.find(source.account.id)
    forged.family_id = other.family_id
    assert_raises(Binding::Conflict) { Binding.capture!(account: forged, account_provider: source.link) }
    UpAccount.where(id: source.legacy.id).delete_all

    assert_no_difference "Account::IngestionIdentity.count" do
      assert_raises(Binding::Conflict) { Binding.capture!(account: source.account, account_provider: source.link) }
    end
    refute Account::IngestionIdentity.exists?(source.account.id)
  end

  test "capture rejects a polymorphic source outside the provider manifest" do
    account = financial_account
    link = AccountProvider.create!(account: account, family: account.family, provider: securities(:aapl))

    assert_no_difference "Account::IngestionIdentity.count" do
      assert_raises(Binding::Conflict) { Binding.capture!(account: account, account_provider: link) }
    end
  end

  test "handover retains immutable inactive policy history after its old link is removed" do
    with_provider_encryption do
      first = native_source
      second = native_source(account: first.account, provider_key: "plaid")
      original = select_policy(first)
      original_binding = original.source_binding.deep_dup
      selected = select_policy(second)

      refute original.reload.active?
      assert_equal 2, selected.revision
      assert_equal original_binding, original.source_binding
      assert_no_difference "Policy.count" { first.link.destroy! }
      assert_nil original.reload.account_provider
      assert original.valid?, original.errors.full_messages.join(", ")
      assert Binding.validate!(original.source_binding, policy: original)
      assert_equal original_binding, original.source_binding
      assert_equal [ selected.id ], Policy.active.where(account_id: first.account.id).pluck(:id)
      assert_equal first.link.id, original.account_provider_id
    end
  end

  test "an active policy prevents raw deletion of its provider link" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)

      assert_database_failure(error: ActiveRecord::InvalidForeignKey) { AccountProvider.where(id: source.link.id).delete_all }

      assert source.link.reload.persisted?
      assert policy.reload.active?
      assert_equal expected_binding(source), policy.source_binding
    end
  end

  test "unknown old revisions remain unknown and selection creates a new bound revision" do
    with_provider_encryption do
      source = native_source
      unknown = insert_unknown_policy(source)
      before = unknown.attributes
      selected = nil

      assert_difference "Policy.count", 1 do
        selected = select_policy(source)
      end

      refute unknown.reload.active?
      assert_equal({}, unknown.source_binding)
      assert_equal before.except("active", "updated_at"), unknown.attributes.except("active", "updated_at")
      assert_equal 2, selected.revision
      assert_equal expected_binding(source), selected.source_binding
      assert_no_difference "Policy.count" { assert_equal selected.id, select_policy(source).id }
      Policy.where(id: selected.id).update_all(active: false)
      assert_database_failure(error: ActiveRecord::InvalidForeignKey) { AccountProvider.where(id: source.link.id).delete_all }
      assert AccountProvider.exists?(source.link.id), "even an inactive unknown revision must retain its original link"
      assert_database_failure { Policy.where(id: unknown.id).update_all(source_binding: selected.source_binding) }
      assert_equal({}, unknown.reload.source_binding)
    end
  end

  test "raw changes cannot rewrite a captured policy owner or revision" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      original = policy.reload.attributes
      [ { source_binding: {} }, { source_binding: policy.source_binding.merge("external_account_id" => SecureRandom.uuid) },
        { account_provider_id: SecureRandom.uuid }, { revision: policy.revision + 1 }, { resource: "holdings" } ].each do |change|
        assert_database_failure { Policy.where(id: policy.id).update_all(change) }
        assert_equal original, policy.reload.attributes
      end
    end
  end

  test "direct insertion rejects a captured origin which differs from the exact live link" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source).reload
      other_connection = create_provider_connection(family: families(:empty))
      other_external = create_external_account(source.connection)
      attributes = policy.attributes.except("required_account_provider_id", "source_external_account_id",
        "source_provider_connection_id", "source_provider_key").merge("id" => SecureRandom.uuid, "revision" => 2, "active" => false)
      [ { "external_account_id" => other_external.id },
        { "provider_connection_id" => other_connection.id } ].each do |change|
        assert_database_failure do
          Policy.insert_all!([ attributes.merge("source_binding" => policy.source_binding.merge(change)) ])
        end
      end
      assert_equal [ policy.id ], Policy.where(account_id: source.account.id).pluck(:id)
    end
  end

  test "legacy link enrichment without an exact copier mapping is rejected at the deferred boundary" do
    with_provider_encryption do
      source = legacy_source
      policy = select_policy(source)
      original = source.link.reload.attributes
      external = create_external_account(create_provider_connection(family: source.account.family))

      assert_database_failure do
        AccountProvider.where(id: source.link.id).update_all(external_account_id: external.id, provider_key: "up")
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_provider_retained_source_enrichment IMMEDIATE")
      end

      assert_equal original, source.link.reload.attributes
      assert_nil policy.reload.source_binding.fetch("external_account_id")
    end
  end

  test "a detached inactive policy cannot reactivate without its original provider link" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      Policy.where(id: policy.id).update_all(active: false)
      source.link.destroy!

      policy.reload.active = true
      refute policy.save
      assert_database_failure { Policy.where(id: policy.id).update_all(active: true) }
      refute policy.reload.active?
      assert_nil policy.account_provider
    end
  end

  test "retained provider-link UUIDs cannot be reused by insertion or primary-key mutation" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      original_link = source.link.reload.attributes
      Policy.where(id: policy.id).update_all(active: false)
      source.link.destroy!
      other = native_source(account: source.account, provider_key: "plaid")

      assert_database_failure { AccountProvider.insert_all!([ original_link ]) }
      assert_database_failure { AccountProvider.where(id: other.link.id).update_all(id: source.link.id) }

      refute AccountProvider.exists?(source.link.id)
      assert_equal source.link.id, policy.reload.account_provider_id
      assert AccountProvider.exists?(other.link.id)
    end
  end

  test "a selected link cannot switch its shared source behind the immutable policy" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      replacement = create_external_account(source.connection)

      assert_database_failure { AccountProvider.where(id: source.link.id).update_all(external_account_id: replacement.id) }

      assert_equal source.external.id, source.link.reload.external_account_id
      assert_equal source.external.id, policy.reload.source_binding.fetch("external_account_id")
    end
  end

  test "policy-only account history refuses destruction and deletion scheduling before financial changes" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      Policy.where(id: policy.id).update_all(active: false)
      source.link.destroy!
      original = source.account.reload.attributes
      source.account.expects(:cleanup_transfers).never
      DestroyJob.expects(:perform_later).never

      assert_equal false, source.account.destroy
      assert_raises(ActiveRecord::RecordNotDestroyed) { source.account.destroy_later }

      assert_equal original, source.account.reload.attributes
      assert_equal policy.id, Policy.find(policy.id).id
      assert_database_failure(error: ActiveRecord::InvalidForeignKey) { Account.where(id: source.account.id).delete_all }
    end
  end

  test "inactive bound policy validates after an atomic database-only retirement of its live Account" do
    with_provider_encryption do
      source = native_source
      policy = select_policy(source)
      original_binding = policy.source_binding.deep_dup
      Policy.where(id: policy.id).update_all(active: false)
      source.link.destroy!

      ApplicationRecord.transaction(requires_new: true) do
        # This rollback fixture proves retained FKs and validation only. It is
        # not a public account-retirement command or a deletion authorization.
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement DEFERRED")
        Account::IngestionIdentity.where(id: source.account.id).update_all(live_account_id: nil, retired_at: Time.current)
        Account.where(id: source.account.id).delete_all
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")

        policy.reload
        assert_nil policy.account
        assert_nil policy.account_provider
        assert policy.account_identity.retired?
        assert policy.valid?, policy.errors.full_messages.join(", ")
        assert_equal original_binding, policy.source_binding
        assert Binding.validate!(policy.source_binding, policy: policy)
        raise ActiveRecord::Rollback
      end
      assert Account.exists?(source.account.id)
      refute policy.reload.account_identity.retired?
    end
  end

  test "policy retention guards are installed including deferred copier enrichment validation" do
    names = ApplicationRecord.connection.select_values(<<~SQL)
      SELECT tgname FROM pg_trigger WHERE NOT tgisinternal AND tgname IN (
        'account_source_policy_retention_guard', 'account_provider_retained_identity_guard',
        'account_provider_retained_source_enrichment') ORDER BY tgname
    SQL
    assert_equal %w[account_provider_retained_identity_guard account_provider_retained_source_enrichment account_source_policy_retention_guard], names
    assert_equal true, ApplicationRecord.connection.select_value(<<~SQL)
      SELECT tgdeferrable AND tginitdeferred FROM pg_trigger
      WHERE tgname = 'account_provider_retained_source_enrichment' AND NOT tgisinternal
    SQL
  end

  private

    def financial_account(family: families(:dylan_family))
      family.accounts.create!(name: "Source binding account", currency: "USD", balance: 0, accountable: Depository.new)
    end

    def native_source(account: financial_account, provider_key: "up")
      connection = create_provider_connection(family: account.family, provider_key: provider_key)
      external = create_external_account(connection)
      link = AccountProvider.create!(account: account, external_account: external)
      Source.new(account, link, external, connection, nil, nil)
    end

    def legacy_source
      with_provider_encryption do
        account = financial_account
        item = UpItem.create!(family: account.family, name: "Legacy policy owner", access_token: "private-legacy-binding-token")
        legacy = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD")
        link = AccountProvider.create!(account: account, family: account.family, provider: legacy)
        Source.new(account, link, nil, nil, legacy, item)
      end
    end

    def select_policy(source)
      Policy.select!(account: source.account, account_provider: source.link, resource: "balances")
    end

    def expected_binding(source)
      { "format" => Binding::FORMAT, "capture_kind" => "selection", "account_id" => source.account.id,
        "family_id" => source.account.family_id, "account_provider_id" => source.link.id,
        "provider_key" => source.connection&.provider_key || "up",
        "external_account_id" => source.external&.id, "provider_connection_id" => source.connection&.id,
        "legacy_account_type" => source.legacy&.class&.name, "legacy_account_id" => source.legacy&.id,
        "legacy_item_type" => source.item&.class&.name, "legacy_item_id" => source.item&.id }
    end

    def insert_unknown_policy(source)
      # Represent a pre-binding/old-worker revision through the allowed SQL
      # rollout path. Its empty proof must never be filled from current links.
      Account::IngestionIdentity.capture!(account: source.account)
      id = SecureRandom.uuid
      Policy.insert_all!([ { id: id, account_id: source.account.id, family_id: source.account.family_id,
        account_provider_id: source.link.id, resource: "balances", revision: 1, active: true, source_binding: {},
        created_at: Time.current, updated_at: Time.current } ])
      Policy.find(id)
    end

    def assert_database_failure(error: ActiveRecord::StatementInvalid)
      assert_raises(error) { ApplicationRecord.transaction(requires_new: true) { yield } }
    end
end

class Account::SourcePolicy::CopiedBindingTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "a genuine copied dual source binds both original legacy and shared owners" do
    with_identity_source(quiesced: false) do |context|
      policy = Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "balances")
      binding = policy.source_binding

      assert_equal context.account.id, binding.fetch("account_id")
      assert_equal context.family.id, binding.fetch("family_id")
      assert_equal context.link.id, binding.fetch("account_provider_id")
      assert_equal context.external.id, binding.fetch("external_account_id")
      assert_equal context.control.provider_connection_id, binding.fetch("provider_connection_id")
      assert_equal "UpAccount", binding.fetch("legacy_account_type")
      assert_equal context.source.id, binding.fetch("legacy_account_id")
      assert_equal "UpItem", binding.fetch("legacy_item_type")
      assert_equal context.item.id, binding.fetch("legacy_item_id")
      assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
      assert context.control.reload.shadow?
      assert context.control.provider_connection.disabled?
    end
  end

  test "actual copier enrichment preserves an already selected legacy policy verbatim" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = UpItem.create!(family: family, name: "Selected before copy", access_token: "private-binding-copy-token")
      account = family.accounts.create!(name: "Original financial identity", currency: "USD", balance: 0, accountable: Depository.new)
      begin
        source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", raw_transactions_payload: [])
        link = AccountProvider.create!(account: account, family: family, provider: source)
        policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
        original = policy.reload.attributes
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1)
        control = nil
        15.times do
          control = copier.run.reload
          break if control.shadow?
        end

        assert control.shadow?
        assert control.provider_connection.disabled?
        external = control.provider_connection.external_accounts.sole
        assert_equal external.id, link.reload.external_account_id
        assert_equal original, policy.reload.attributes
        assert_nil policy.source_binding.fetch("external_account_id")
        assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
        assert_no_difference "Account::SourcePolicy.count" do
          assert_equal policy.id, Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances").id
        end
        fresh = Account::SourcePolicy::Binding.capture!(account: account, account_provider: link)
        assert_equal external.id, fresh.fetch("external_account_id")
        assert_equal source.id, fresh.fetch("legacy_account_id")
        assert_equal original, policy.reload.attributes
      ensure
        cleanup_identity_source(item, account)
      end
    end
  end

  test "raw dual policy cannot pair a legacy source with another copied source and control" do
    with_identity_source(quiesced: false) do |first|
      with_identity_source(quiesced: false) do |second|
        [ first, second ].each do |context|
          Account::SourcePolicy.where(account_id: context.account.id).update_all(active: false)
          context.link.destroy!
        end
        mismatched = AccountProvider.create!(account: second.account, provider: second.source, external_account: first.external)
        original = Account::SourcePolicy.find_by!(account_id: second.account.id, resource: "transactions")
        binding = original.source_binding.merge("account_provider_id" => mismatched.id,
          "external_account_id" => first.external.id, "provider_connection_id" => first.control.provider_connection_id)
        attributes = original.attributes.except("required_account_provider_id", "source_external_account_id",
          "source_provider_connection_id", "source_provider_key").merge("id" => SecureRandom.uuid,
            "account_provider_id" => mismatched.id, "revision" => 2, "source_binding" => binding)

        assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) { Account::SourcePolicy.insert_all!([ attributes ]) }
        end

        assert_equal [ original.id ], Account::SourcePolicy.where(account_id: second.account.id).pluck(:id)
        assert_equal second.external.id, original.reload.source_binding.fetch("external_account_id")
        assert_equal second.control.provider_connection_id, original.source_binding.fetch("provider_connection_id")
      end
    end
  end
end
