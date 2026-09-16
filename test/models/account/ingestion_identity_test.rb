require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Account::IngestionIdentityTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper

  Identity = Account::IngestionIdentity
  Source = Data.define(:account, :connection, :external, :link, :policy)
  Publication = Data.define(:source_record, :entry, :evidence, :batch)

  test "native source selection and financial publication capture the original account UUID exactly once" do
    with_source(policy: false) do |source|
      published = nil
      assert_difference "Identity.count", 1 do
        published = publish_transaction(source)
      end
      identity = Identity.find(source.account.id)

      assert_equal source.account.id, identity.live_account_id
      assert_equal source.account.family_id, identity.family_id
      assert_nil identity.retired_at
      assert_equal identity, published.source_record.reload.account_identity
      assert_equal identity, published.evidence.reload.account_identity
      assert_equal source.account.id, published.source_record.account_id
      assert_equal published.entry.id, published.evidence.entry_identity
      assert_no_difference "Identity.count" do
        assert_equal identity.id, Identity.capture!(account: source.account).id
        publish_transaction(source)
      end
      assert_equal identity.created_at, identity.reload.created_at
    end
  end

  test "unbound observations do not create an account identity until actual first publication" do
    with_source(policy: false) do |source|
      external_id = SecureRandom.uuid
      batch = create_provider_batch(source.connection, external_account: source.external, stream: "transactions",
        scope_key: "account:#{source.external.id}")
      record = nil
      assert_no_difference "Identity.count" do
        record = SourceRecord.create!(family: source.account.family, external_account: source.external,
          ingestion_batch: batch, kind: "transaction", external_id: external_id)
      end
      assert_nil record.account_id
      assert_nil record.account_identity

      assert_difference "Identity.count", 1 do
        assert_no_difference "SourceRecord.count" { publish_transaction(source, external_id: external_id) }
      end
      assert_equal source.account.id, record.reload.account_identity.id
      assert_equal source.account.family_id, record.account_identity.family_id
    end
  end

  test "capture refuses transient forged-family and missing financial receivers" do
    account = financial_account
    transient = Account.new(id: account.id, family_id: account.family_id)
    foreign = Account.find(account.id)
    foreign.family_id = families(:empty).id
    missing = financial_account
    Account.where(id: missing.id).delete_all

    [ transient, foreign, missing ].each do |receiver|
      assert_no_difference "Identity.count" do
        assert_raises(Identity::Conflict) { Identity.capture!(account: receiver) }
      end
    end
  end

  test "failed publication rolls back its newly captured identity with the source observation" do
    with_source(policy: false) do |source|
      before = [ Identity.count, SourceRecord.count, EntrySource.count, source.account.entries.count ]
      ApplicationRecord.transaction(requires_new: true) do
        publish_transaction(source)
        assert Identity.exists?(source.account.id)
        raise ActiveRecord::Rollback
      end

      assert_equal before, [ Identity.count, SourceRecord.count, EntrySource.count, source.account.entries.count ]
      refute Identity.exists?(source.account.id)
    end
  end

  test "raw bound-source rebinding clearing and family substitution are rejected" do
    with_source do |source|
      record = publish_transaction(source).source_record
      other = financial_account
      Identity.capture!(account: other)
      [ { account_id: nil }, { account_id: other.id }, { family_id: families(:empty).id } ].each do |change|
        assert_database_failure do
          SourceRecord.where(id: record.id).update_all(change)
        end
        assert_equal source.account.id, record.reload.account_id
        assert_equal source.account.family_id, record.family_id
      end
    end
  end

  test "a direct bound observation insert cannot invent a missing retained account identity" do
    with_source(policy: false) do |source|
      batch = create_provider_batch(source.connection, external_account: source.external, stream: "transactions")
      assert_database_failure(error: ActiveRecord::InvalidForeignKey) do
        SourceRecord.insert_all!([ {
          id: SecureRandom.uuid, family_id: source.account.family_id, account_id: source.account.id,
          external_account_id: source.external.id, ingestion_batch_id: batch.id,
          kind: "transaction", external_id: "missing-identity", input_external_id: "missing-identity",
          input_occurrence: 0, observation_order: [], created_at: Time.current, updated_at: Time.current
        } ])
      end
      refute Identity.exists?(source.account.id)
    end
  end

  test "Account destroy refuses before entries holdings links or evidence are changed" do
    with_source do |source|
      published = publish_transaction(source)
      holding, holding_source = publish_holding(source)
      original = [ source.account.reload.attributes, published.entry.reload.attributes,
        published.source_record.reload.attributes, published.evidence.reload.attributes,
        holding.reload.attributes, holding_source.reload.attributes, source.link.reload.attributes ]
      source.account.expects(:cleanup_transfers).never

      queries = capture_sql_queries { assert_equal false, source.account.destroy }

      assert source.account.errors[:base].any?
      refute source.account.destroyed?
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal original, [ source.account.reload.attributes, published.entry.reload.attributes,
        published.source_record.reload.attributes, published.evidence.reload.attributes,
        holding.reload.attributes, holding_source.reload.attributes, source.link.reload.attributes ]
    end
  end

  test "raw Account deletion cannot bypass the live identity foreign key" do
    account = financial_account
    identity = Identity.capture!(account: account)
    entry = account.entries.create!(name: "Retain this entry", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)

    error = assert_database_failure(error: ActiveRecord::InvalidForeignKey) do
      Account.where(id: account.id).delete_all
    end

    assert_includes error.message, "fk_ingestion_account_identity_live"
    assert Account.exists?(account.id)
    assert Entry.exists?(entry.id)
    assert_equal account.id, identity.reload.live_account_id
  end

  test "scheduling deletion of published evidence rolls back status and enqueues nothing" do
    with_source do |source|
      published = publish_transaction(source)
      original = source.account.reload.attributes
      DestroyJob.expects(:perform_later).never

      assert_no_enqueued_jobs do
        assert_raises(ActiveRecord::RecordNotDestroyed) { source.account.destroy_later }
      end

      assert_equal original, source.account.reload.attributes
      assert published.evidence.reload.active?
      assert Entry.exists?(published.entry.id)
    end
  end

  test "an unpublished account scheduled for deletion cannot receive its first bound observation" do
    with_source(policy: false) do |source|
      batch = create_provider_batch(source.connection, external_account: source.external, stream: "transactions")
      original_receiver = Account.find(source.account.id)
      DestroyJob.expects(:perform_later).with(source.account).once
      source.account.destroy_later

      assert source.account.reload.pending_deletion?
      refute original_receiver.pending_deletion?
      assert_raises(Identity::Conflict) { Identity.capture!(account: original_receiver) }
      assert_no_difference "SourceRecord.count" do
        assert_raises(Identity::Conflict) do
          SourceRecord.create!(family: source.account.family, account: original_receiver,
            external_account: source.external, ingestion_batch: batch, kind: "transaction", external_id: SecureRandom.uuid)
        end
      end
      refute Identity.exists?(source.account.id)
    end
  end

  test "a pending deletion rejects raw observations even when an unused live identity already exists" do
    with_source(policy: false) do |source|
      identity = Identity.capture!(account: source.account)
      batch = create_provider_batch(source.connection, external_account: source.external, stream: "transactions")
      DestroyJob.expects(:perform_later).with(source.account).once
      source.account.destroy_later

      error = assert_database_failure do
        SourceRecord.insert_all!([ {
          id: SecureRandom.uuid, family_id: source.account.family_id, account_id: source.account.id,
          external_account_id: source.external.id, ingestion_batch_id: batch.id,
          kind: "transaction", external_id: "after-deletion-scheduled", input_external_id: "after-deletion-scheduled",
          input_occurrence: 0, observation_order: [], created_at: Time.current, updated_at: Time.current
        } ])
      end

      assert_includes error.message, "Account pending deletion cannot receive source observations"
      assert source.account.reload.pending_deletion?
      assert_equal source.account.id, identity.reload.live_account_id
      assert_empty identity.source_records
    end
  end

  test "modeled retirement is refused even when no financial evidence remains active" do
    with_source do |source|
      published = publish_transaction(source)
      detach_evidence(source.account)
      identity = Identity.find(source.account.id)
      identity.assign_attributes(live_account_id: nil, retired_at: Time.current)

      refute identity.save

      assert identity.errors[:base].any?
      refute identity.reload.retired?
      assert_equal source.account.id, identity.live_account_id
      assert Entry.exists?(published.entry.id)
    end
  end

  test "database retirement requires both entry and holding evidence to be detached and inactive" do
    with_source do |source|
      published = publish_transaction(source)
      _holding, holding_source = publish_holding(source)
      identity = Identity.find(source.account.id)
      assert_database_failure { raw_retire_identity(identity) }
      EntrySource.where(id: published.evidence.id).update_all(entry_id: nil, active: false)
      assert_database_failure { raw_retire_identity(identity) }
      assert holding_source.reload.active?
      assert_equal source.account.id, identity.reload.live_account_id
    end
  end

  test "a detached identity cannot retire while the live Account remains at constraint evaluation" do
    with_source do |source|
      publish_transaction(source)
      detach_evidence(source.account)
      identity = Identity.find(source.account.id)

      assert_database_failure do
        raw_retire_identity(identity)
        check_retirement_constraint!
      end

      refute identity.reload.retired?
      assert_equal source.account.id, identity.live_account_id
      assert Account.exists?(source.account.id)
    end
  end

  test "an atomic database fixture can retain detached evidence after deleting the original live Account" do
    with_source do |source|
      published = publish_transaction(source)
      holding, holding_source = publish_holding(source)
      historical = [ source.account.id, published.entry.id, holding.id, published.source_record.id, published.evidence.id, holding_source.id ]

      retire_fixture(source.account)

      identity = Identity.find(historical[0])
      assert identity.retired?
      assert_nil identity.live_account_id
      refute Account.exists?(historical[0])
      refute Entry.exists?(historical[1])
      refute Holding.exists?(historical[2])
      assert_equal historical[0], published.source_record.reload.account_id
      assert_nil published.source_record.account
      assert published.source_record.valid?, published.source_record.errors.full_messages.join(", ")
      assert_equal historical[1], published.evidence.reload.entry_identity
      assert_nil published.evidence.entry_id
      refute published.evidence.active?
      assert published.evidence.valid?, published.evidence.errors.full_messages.join(", ")
      assert_equal historical[2], holding_source.reload.holding_identity
      assert_nil holding_source.holding_id
      refute holding_source.active?
      assert holding_source.valid?, holding_source.errors.full_messages.join(", ")
      assert_equal historical[3..], [ published.source_record.id, published.evidence.id, holding_source.id ]
      assert_raises(Identity::Conflict) { Identity.capture!(account: source.account) }
    end
  end

  test "rollback of raw retirement restores the live identity and all financial pointers" do
    with_source do |source|
      published = publish_transaction(source)
      holding, holding_source = publish_holding(source)
      identity = Identity.find(source.account.id)
      original = [ identity.attributes, published.evidence.attributes, holding_source.attributes ]

      ApplicationRecord.transaction(requires_new: true) do
        retire_fixture(source.account)
        assert Identity.find(source.account.id).retired?
        raise ActiveRecord::Rollback
      end

      assert Account.exists?(source.account.id)
      assert Entry.exists?(published.entry.id)
      assert Holding.exists?(holding.id)
      assert_equal original, [ identity.reload.attributes, published.evidence.reload.attributes, holding_source.reload.attributes ]
    end
  end

  test "retired account UUIDs cannot be recreated or their identities rewound" do
    with_source do |source|
      publish_transaction(source)
      account_attributes = source.account.reload.attributes
      another_account = financial_account
      retire_fixture(source.account)
      identity = Identity.find(source.account.id)

      assert_database_failure { Account.insert_all!([ account_attributes ]) }
      assert_database_failure { Account.create!(account_attributes) }
      assert_database_failure { Account.where(id: another_account.id).update_all(id: identity.id) }
      assert_database_failure { identity.update_columns(live_account_id: identity.id, retired_at: nil) }
      assert_database_failure { identity.update_columns(retired_at: identity.retired_at + 1.second) }
      assert identity.reload.retired?
      refute Account.exists?(identity.id)
    end
  end

  test "retired observations reject modeled raw and new-source updates" do
    with_source do |source|
      published = publish_transaction(source)
      retire_fixture(source.account)
      record = published.source_record.reload
      record.pending = !record.pending
      refute record.save
      record.reload

      assert_database_failure { SourceRecord.where(id: record.id).update_all(withdrawn: !record.withdrawn) }
      replacement = record.attributes.merge("id" => SecureRandom.uuid, "external_id" => SecureRandom.uuid,
        "input_external_id" => SecureRandom.uuid)
      assert_database_failure { SourceRecord.insert_all!([ replacement ]) }
      assert_equal source.account.id, record.reload.account_id
      assert record.valid?, record.errors.full_messages.join(", ")
    end
  end

  test "evidence cannot change its original pointer identity or reactivate after retirement" do
    with_source do |source|
      published = publish_transaction(source)
      holding, holding_source = publish_holding(source)
      another = source.account.entries.create!(name: "Another", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
      assert_database_failure { EntrySource.where(id: published.evidence.id).update_all(entry_id: another.id) }
      assert_database_failure { HoldingSource.where(id: holding_source.id).update_all(holding_identity: SecureRandom.uuid) }
      retire_fixture(source.account)

      assert_database_failure { EntrySource.where(id: published.evidence.id).update_all(entry_id: published.entry.id, active: true) }
      assert_database_failure { HoldingSource.where(id: holding_source.id).update_all(holding_id: holding.id, active: true) }
      assert_nil published.evidence.reload.entry_id
      assert_nil holding_source.reload.holding_id
      new_entry_evidence = published.evidence.attributes.except("id", "created_at", "updated_at")
      new_holding_evidence = holding_source.attributes.except("id", "created_at", "updated_at")
      refute EntrySource.new(new_entry_evidence).valid?
      refute HoldingSource.new(new_holding_evidence).valid?
      assert_database_failure { EntrySource.insert_all!([ new_entry_evidence.merge("id" => SecureRandom.uuid) ]) }
      assert_database_failure { HoldingSource.insert_all!([ new_holding_evidence.merge("id" => SecureRandom.uuid) ]) }
    end
  end

  test "the database has every identity guard including its deferred retirement constraint" do
    names = ApplicationRecord.connection.select_values(<<~SQL)
      SELECT tgname FROM pg_trigger WHERE NOT tgisinternal AND tgname IN (
        'account_ingestion_identity_guard', 'source_record_ingestion_identity_guard',
        'entry_source_ingestion_identity_guard', 'holding_source_ingestion_identity_guard',
        'account_ingestion_identity_no_resurrection', 'account_ingestion_identity_retirement')
      ORDER BY tgname
    SQL
    assert_equal %w[account_ingestion_identity_guard account_ingestion_identity_no_resurrection account_ingestion_identity_retirement
      entry_source_ingestion_identity_guard holding_source_ingestion_identity_guard source_record_ingestion_identity_guard].sort, names
    deferrable = ApplicationRecord.connection.select_value(<<~SQL)
      SELECT tgdeferrable AND tginitdeferred FROM pg_trigger
      WHERE tgname = 'account_ingestion_identity_retirement' AND NOT tgisinternal
    SQL
    assert_equal true, deferrable
  end

  private

    def financial_account(family: families(:dylan_family))
      family.accounts.create!(name: "Ingestion identity account", currency: "USD", balance: 0, accountable: Investment.new)
    end

    def with_source(policy: true)
      with_provider_encryption do
        account = financial_account
        connection = create_provider_connection(family: account.family)
        external = create_external_account(connection)
        link = AccountProvider.create!(account: account, external_account: external)
        selected = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions") if policy
        yield Source.new(account, connection, external, link, selected)
      end
    end

    def publish_transaction(source, external_id: SecureRandom.uuid)
      policy = source.policy || Account::SourcePolicy.select!(account: source.account, account_provider: source.link, resource: "transactions")
      record = Ingestion::Record.transaction(external_id: external_id, name: "Original provider transaction",
        amount: BigDecimal("12.34"), currency: "USD", date: Date.current, pending: false)
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "delta")
      batch = create_provider_batch(source.connection, external_account: source.external, stream: "transactions",
        scope_key: "account:#{source.external.id}", source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
      Ingestion::LedgerWriter.new(external_account: source.external, batch: batch).apply(page)
      observation = SourceRecord.find_by!(external_account: source.external, kind: "transaction", external_id: external_id)
      Publication.new(observation, observation.entry, observation.entry_source, batch)
    end

    def publish_holding(source)
      policy = Account::SourcePolicy.select!(account: source.account, account_provider: source.link, resource: "holdings")
      batch = create_provider_batch(source.connection, external_account: source.external, stream: "holdings",
        scope_key: "account:#{source.external.id}", source_policy_version: policy.id)
      record = SourceRecord.create!(family: source.account.family, account: source.account, external_account: source.external,
        ingestion_batch: batch, kind: "holding", external_id: SecureRandom.uuid)
      holding = source.account.holdings.create!(security: securities(:aapl), account_provider: source.link,
        date: Date.current, currency: "USD", qty: 1, price: 10, amount: 10)
      evidence = HoldingSource.create!(source_record: record, family: source.account.family, account: source.account,
        holding: holding, role: "posting")
      [ holding, evidence ]
    end

    def detach_evidence(account)
      EntrySource.where(account_id: account.id).update_all(entry_id: nil, active: false)
      HoldingSource.where(account_id: account.id).update_all(holding_id: nil, active: false)
    end

    def raw_retire_identity(identity)
      Identity.where(id: identity.id).update_all(live_account_id: nil, retired_at: Time.current)
    end

    def retire_fixture(account)
      # This is a database invariant fixture, not a public retirement command.
      # Its disposable policies/links are removed explicitly; production must
      # still define their retained disposition. Entries/holdings have cascade
      # FKs, and this fixture creates no Account SyncInput, goal or share rows.
      # All tests roll back, and the deferred check is explicitly evaluated.
      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement DEFERRED")
        detach_evidence(account)
        Account::SourcePolicy.where(account_id: account.id).delete_all
        AccountProvider.where(account_id: account.id).find_each(&:destroy!)
        raw_retire_identity(Identity.find(account.id))
        Account.where(id: account.id).delete_all
        check_retirement_constraint!
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement DEFERRED")
      end
    end

    def check_retirement_constraint!
      ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
    end

    def assert_database_failure(error: ActiveRecord::StatementInvalid)
      assert_raises(error) { ApplicationRecord.transaction(requires_new: true) { yield } }
    end
end

class Account::IngestionIdentityContentionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup { Family.any_instance.stubs(:broadcast_refresh) }

  test "deletion must acquire the Account lock even before the first ingestion identity exists" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    family = Family.create!(name: "First identity contention")
    account = family.accounts.create!(name: "First publication", currency: "USD", balance: 0, accountable: Depository.new)
    original = account.attributes
    ready, release = Queue.new, Queue.new
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        Account.transaction do
          current = Account.lock.find(account.id)
          ready << true
          release.pop
          Account::IngestionIdentity.capture!(account: current).id
        end
      end
    end

    begin
      Timeout.timeout(5) { ready.pop }
      refute Account::IngestionIdentity.exists?(account.id)
      account.expects(:cleanup_transfers).never

      assert_equal false, account.destroy

      assert account.errors[:base].any?
      assert_equal original, account.reload.attributes
      refute account.destroyed?
    ensure
      release << true
      begin
        identity_id = Timeout.timeout(5) { worker.value }
      ensure
        worker.kill if worker.alive?
        worker.join
      end
    end

    assert_equal account.id, identity_id
    assert_equal account.id, Account::IngestionIdentity.find(account.id).live_account_id
  ensure
    Account.find(account.id).destroy! if account&.persisted? && Account.exists?(account.id)
    family&.destroy!
    clear_enqueued_jobs
  end
end

class Account::IngestionIdentityBootstrapTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "genuine migration identity publication captures the existing financial UUID without replacing ledger rows" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_identity-retained", user_modified: true)
      original = [ entry.id, entry.entryable_id, entry.reload.attributes, entry.entryable.attributes ]

      original_identity = Account::IngestionIdentity.find(context.account.id)
      assert_no_difference "Account::IngestionIdentity.count" do
        Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      end

      identity = Account::IngestionIdentity.find(context.account.id)
      assert_equal original_identity.attributes, identity.attributes
      evidence = EntrySource.find_by!(entry_identity: entry.id, bootstrap_external_account: context.external)
      assert_equal context.family.id, identity.family_id
      assert_equal context.account.id, identity.live_account_id
      assert_equal identity.id, evidence.source_record.account_identity.id
      assert_equal original, [ entry.id, entry.entryable_id, entry.reload.attributes, entry.entryable.reload.attributes ]
      assert context.control.reload.quiescing?
      assert context.control.provider_connection.disabled?

      retained_batch = evidence.bootstrap_batch
      original_cipher = ApplicationRecord.connection.select_value(IngestionBatch.where(id: retained_batch.id).select(:payload).to_sql)
      original_batch = retained_batch.attributes
      original_proof = Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: evidence, source_record: evidence.source_record)
      ApplicationRecord.transaction(requires_new: true) do
        # Deliberately dispose only this rollback fixture's financial graph;
        # a production retirement must retain/dispose its policies explicitly.
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement DEFERRED")
        EntrySource.where(id: evidence.id).update_all(entry_id: nil, active: false)
        Account::SourcePolicy.where(account_id: context.account.id).delete_all
        AccountProvider.where(account_id: context.account.id).delete_all
        Account::IngestionIdentity.where(id: identity.id).update_all(live_account_id: nil, retired_at: Time.current)
        Account.where(id: context.account.id).delete_all
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")

        assert_nil evidence.reload.entry_id
        assert_equal entry.id, evidence.entry_identity
        assert_equal retained_batch.id, evidence.bootstrap_batch_id
        assert_equal original_proof, Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: evidence, source_record: evidence.source_record)
        assert evidence.valid?, evidence.errors.full_messages.join(", ")
        assert_equal original_batch, retained_batch.reload.attributes
        assert_equal original_cipher, ApplicationRecord.connection.select_value(IngestionBatch.where(id: retained_batch.id).select(:payload).to_sql)
        raise ActiveRecord::Rollback
      end

      assert_equal context.account.id, identity.reload.live_account_id
      assert_equal original, [ entry.id, entry.entryable_id, entry.reload.attributes, entry.entryable.reload.attributes ]
    end
  end
end
