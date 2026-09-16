require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class ProviderConnection::AccountSetupTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Setup = ProviderConnection::AccountSetup

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
  end

  teardown do
    clear_enqueued_jobs
  end

  test "catalog exposes unlinked native discovery and only manageable existing accounts" do
    with_connection do |connection, actor|
      external = create_external_account(connection)
      create_external_account(connection, status: "ignored")
      create_external_account(connection, status: "closed")
      owned = financial_account(actor)
      linked_external = create_external_account(connection)
      AccountProvider.create!(account: financial_account(actor), external_account: linked_external)
      stranger = actor.family.users.create!(email: "setup-private-#{SecureRandom.uuid}@example.com", password: "setup-password", role: "member")
      private_account = financial_account(stranger)
      Provider::Up.expects(:new).never

      catalog = Setup.new(connection: connection, actor: actor).catalog

      assert_equal connection.id, catalog.connection.id
      assert_equal [ external.id ], catalog.external_accounts.map(&:id)
      assert_includes catalog.existing_accounts.map(&:id), owned.id
      refute_includes catalog.existing_accounts.map(&:id), private_account.id
      assert_equal %w[Depository Loan], catalog.account_types
      assert_nil catalog.next_cursor
    end
  end

  test "creating from discovery uses explicit financial values and queues one native sync after commit" do
    with_connection do |connection, actor|
      external = create_external_account(connection, name: "Remote checking", current_balance: 999)
      command = Setup.new(connection: connection, actor: actor)
      form = command.form(external_account_id: external.id)
      assert_equal %w[Depository Loan], form.account_types
      refute form.secondary
      refute_includes form.token, "private-provider-token"
      Provider::Up.expects(:new).never
      dispatches = []
      dispatch = lambda do |sync|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        dispatches << sync.id
      end

      result = SyncJob.stub(:perform_later, dispatch) do
        command.apply!(token: form.token, attributes: new_attributes("balance" => "12.3456"))
      end

      assert_equal actor.id, result.account.owner_id
      assert_equal actor.family_id, result.account.family_id
      assert_equal "Chosen checking", result.account.name
      assert_equal "USD", result.account.currency
      assert_equal BigDecimal("12.3456"), result.account.balance
      assert_equal "Depository", result.account.accountable_type
      assert_equal external.id, result.account_provider.external_account_id
      assert_equal result.account.id, external.reload.current_account.id
      assert_equal connection.id, result.sync.syncable_id
      assert_equal "ProviderConnection", result.sync.syncable_type
      assert_equal [ result.sync.id ], dispatches
      assert_equal %w[balances transactions], Account::SourcePolicy.active.where(account: result.account).order(:resource).pluck(:resource)
      assert Account::SourcePolicy.where(account: result.account).all? { |policy| policy.account_provider_id == result.account_provider.id && policy.source_binding.present? }
      refute connection.reload.pending_account_setup?
    end
  end

  test "existing account linking preserves its financial rows and existing account identity" do
    with_connection do |connection, actor|
      external = create_external_account(connection, current_balance: 999)
      account = financial_account(actor)
      entry = account.entries.create!(name: "Reviewed", amount: 8, currency: "USD", date: Date.current,
        user_modified: true, import_locked: true, entryable: Transaction.new)
      before = financial_snapshot(account)
      command = Setup.new(connection: connection, actor: actor)
      form = command.form(external_account_id: external.id, account_id: account.id)

      assert_no_difference [ "Account.count", "Entry.count", "Transaction.count", "Valuation.count" ] do
        result = command.apply!(token: form.token, attributes: {})
        assert_equal account.id, result.account.id
      end

      assert_equal before, financial_snapshot(account)
      assert_equal entry.id, account.entries.sole.id
      assert_equal account.id, external.reload.current_account.id
    end
  end

  test "secondary native linkage preserves existing complete resource authorities" do
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
    with_connection do |connection, actor|
      external = create_external_account(connection)
      account = financial_account(actor)
      other = create_provider_connection(family: actor.family, provider_key: "mercury", credentials: { "token" => "other-token" })
      other_external = create_external_account(other)
      primary = AccountProvider.create!(account: account, external_account: other_external)
      Account::SourcePolicy.select_many!(account: account, account_provider: primary, resources: %w[balances transactions])
      policies = Account::SourcePolicy.where(account: account).order(:id).map(&:attributes)
      before = financial_snapshot(account)
      command = Setup.new(connection: connection, actor: actor)
      form = command.form(external_account_id: external.id, account_id: account.id)
      assert form.secondary

      result = command.apply!(token: form.token, attributes: {})

      assert_equal 2, account.account_providers.count
      refute_equal primary.id, result.account_provider.id
      assert_equal policies, Account::SourcePolicy.where(account: account).order(:id).map(&:attributes)
      assert_equal before, financial_snapshot(account)
    end
  end

  test "secondary linkage refuses an unfinished source generation even after its Sync fails" do
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
    with_connection do |connection, actor|
      external = create_external_account(connection)
      account = financial_account(actor)
      other = create_provider_connection(family: actor.family, provider_key: "mercury", credentials: { "token" => "other-token" })
      other_external = create_external_account(other)
      primary = AccountProvider.create!(account: account, external_account: other_external)
      Account::SourcePolicy.select_many!(account: account, account_provider: primary, resources: %w[balances transactions])
      command = Setup.new(connection: connection, actor: actor)
      token = command.form(external_account_id: external.id, account_id: account.id).token
      sync = other.syncs.create!
      context = { "version" => 1, "accounts" => Provider::AccountData::GenerationAccounts.new(other).capture }
      generation = other.provider_sync_generations.create!(sync: sync, stream: "transactions", writer_epoch: other.writer_epoch,
        context_snapshot: context,
        account_ids: Provider::AccountData::GenerationAccountIndex.capture_ids(context_snapshot: context, stream: "transactions"))
      sync.update!(status: "failed", completed_at: Time.current)
      assert generation.fetching?
      refute other.syncs.incomplete.exists?
      before = financial_snapshot(account)
      policies = Account::SourcePolicy.where(account: account).order(:id).map(&:attributes)
      link_before = primary.reload.attributes
      generation_before = generation.reload.attributes

      assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
        assert_raises(Setup::Busy) { command.form(external_account_id: external.id, account_id: account.id) }
        assert_raises(Setup::Busy) { command.apply!(token: token, attributes: {}) }
      end

      assert_nil external.reload.current_account
      assert_equal before, financial_snapshot(account)
      assert_equal policies, Account::SourcePolicy.where(account: account).order(:id).map(&:attributes)
      assert_equal link_before, primary.reload.attributes
      assert_equal generation_before, generation.reload.attributes
    end
  end

  test "submission rechecks the actor and the originally displayed external account" do
    [ :demoted, :changed_source ].each do |change|
      with_connection do |connection, actor|
        external = create_external_account(connection)
        command = Setup.new(connection: connection, actor: actor)
        token = command.form(external_account_id: external.id).token
        change == :demoted ? actor.update!(role: "member") : external.update!(currency: "EUR")

        assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
          assert_raises(Setup::Conflict) { command.apply!(token: token, attributes: new_attributes) }
        end
        assert_nil external.reload.current_account
      end
    end
  end

  test "a selection cannot move to another actor connection family or existing account" do
    with_connection do |connection, actor|
      external = create_external_account(connection)
      account = financial_account(actor)
      command = Setup.new(connection: connection, actor: actor)
      token = command.form(external_account_id: external.id, account_id: account.id).token
      second_actor = actor.family.users.create!(email: "setup-second-#{SecureRandom.uuid}@example.com", password: "setup-password", role: "admin")
      second_connection = create_provider_connection(family: actor.family)
      [ [ connection, second_actor ], [ second_connection, actor ], [ connection, users(:family_admin) ] ].each do |target, user|
        assert_no_difference [ "AccountProvider.count", "Sync.count" ] do
          assert_raises(Setup::Conflict) { Setup.new(connection: target, actor: user).apply!(token: token, attributes: {}) }
        end
      end
      assert_raises(ArgumentError, Setup::Conflict) do
        command.apply!(token: token, attributes: { "account_id" => financial_account(actor).id })
      end
      assert_nil external.reload.current_account
    end
  end

  test "provider and financial account work cannot be rebound by a pending setup submission" do
    [ :provider_sync, :account_sync, :lease ].each do |busy|
      with_connection do |connection, actor|
        external = create_external_account(connection)
        account = financial_account(actor)
        command = Setup.new(connection: connection, actor: actor)
        token = command.form(external_account_id: external.id, account_id: account.id).token
        case busy
        when :provider_sync then connection.syncs.create!
        when :account_sync then account.syncs.create!
        when :lease then connection.update!(lease_owner: SecureRandom.uuid, lease_expires_at: 1.minute.ago)
        end

        assert_no_difference [ "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
          assert_raises(Setup::Busy, Setup::Conflict) { command.apply!(token: token, attributes: {}) }
        end
        assert_nil external.reload.current_account
      end
    end
  end

  test "new account values cannot silently default an absent or invalid balance to zero" do
    with_connection do |connection, actor|
      external = create_external_account(connection)
      command = Setup.new(connection: connection, actor: actor)
      token = command.form(external_account_id: external.id).token
      [ new_attributes.except("balance"), new_attributes("balance" => ""), new_attributes("balance" => "NaN"),
        new_attributes("balance" => "Infinity"), new_attributes("accountable_type" => "Investment") ].each do |attributes|
        assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
          assert_raises(ArgumentError, ActiveRecord::RecordInvalid, Setup::Conflict) { command.apply!(token: token, attributes: attributes) }
        end
      end
      assert_nil external.reload.current_account
    end
  end

  test "previous financial source bindings cannot be silently moved to a new account" do
    with_connection do |connection, actor|
      external = create_external_account(connection)
      original = financial_account(actor)
      link = AccountProvider.create!(account: original, external_account: external)
      policy = Account::SourcePolicy.select!(account: original, account_provider: link, resource: "transactions")
      batch = create_provider_batch(connection, external_account: external, stream: "transactions", scope_key: "account:#{external.id}",
        source_policy_version: policy.id)
      record = SourceRecord.create!(family: actor.family, account: original, external_account: external, ingestion_batch: batch,
        kind: "transaction", external_id: "historically-bound")
      batch.sync.update!(status: "completed", completed_at: Time.current)
      Account::SourcePolicy.where(account: original).delete_all
      link.delete
      before = record.reload.attributes

      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
        assert_raises(Setup::Conflict) { Setup.new(connection: connection, actor: actor).form(external_account_id: external.id) }
      end
      assert_equal before, record.reload.attributes
    end
  end

  test "refresh queues discovery without constructing a provider or choosing a financial account" do
    with_connection do |connection, actor|
      create_external_account(connection)
      Provider::Up.expects(:new).never
      command = Setup.new(connection: connection, actor: actor)

      assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count" ] do
        assert_enqueued_with(job: SyncJob) { command.refresh! }
      end
      assert_equal "ProviderConnection", connection.syncs.sole.syncable_type
    end
  end

  test "refresh retries one pending discovery Sync without advancing its provider retry time" do
    with_connection do |connection, actor|
      create_external_account(connection)
      sync = connection.syncs.create!(resume_at: 10.minutes.from_now, provider_attempt: 1)
      original = sync.reload.attributes
      Provider::Up.expects(:new).never
      command = Setup.new(connection: connection, actor: actor)

      2.times do
        result = nil
        assert_no_difference [ "Sync.count", "Account.count", "AccountProvider.count", "Account::SourcePolicy.count" ] do
          assert_enqueued_with(job: SyncJob, args: [ sync ], at: sync.resume_at) { result = command.refresh! }
        end
        assert_equal sync.id, result.id
        assert_equal original, sync.reload.attributes
      end
    end
  end

  test "a failed queue handoff retries the exact committed account link and Sync" do
    with_connection do |connection, actor|
      external = create_external_account(connection)
      command = Setup.new(connection: connection, actor: actor)
      token = command.form(external_account_id: external.id).token
      attributes = new_attributes
      failure = ->(*) { raise IOError, "Queue unavailable" }

      assert_raises(IOError) { SyncJob.stub(:perform_later, failure) { command.apply!(token: token, attributes: attributes) } }

      account = external.reload.current_account
      assert account
      link = external.account_provider
      sync = connection.syncs.sole
      before = financial_snapshot(account)
      policies = Account::SourcePolicy.where(account: account).order(:id).map(&:attributes)
      dispatched = []
      dispatch = lambda do |queued|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        dispatched << queued.id
      end
      result = nil
      assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
        result = SyncJob.stub(:perform_later, dispatch) { command.apply!(token: token, attributes: attributes) }
      end

      assert_equal [ sync.id ], dispatched
      assert_equal [ account.id, link.id, sync.id ], [ result.account.id, result.account_provider.id, result.sync.id ]
      assert_equal before, financial_snapshot(account)
      assert_equal policies, Account::SourcePolicy.where(account: account).order(:id).map(&:attributes)
      assert_raises(Setup::Conflict) { command.apply!(token: token, attributes: new_attributes("balance" => "99")) }
    end
  end

  test "a genuinely copied unlinked Up account is set up without rewriting its original archives" do
    with_migrated_unlinked do |connection, actor, external, source, mapping|
      archives = connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text"))
      mapping_before = mapping.reload.attributes
      source_before = source.reload.attributes
      command = Setup.new(connection: connection, actor: actor)
      form = command.form(external_account_id: external.id)

      result = command.apply!(token: form.token, attributes: new_attributes)

      assert_equal external.id, result.account_provider.external_account_id
      assert_equal connection.id, result.sync.syncable_id
      assert_equal mapping_before, mapping.reload.attributes
      assert_equal source_before, source.reload.attributes
      assert_equal archives, connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text"))
      assert_equal result.account.id, external.reload.current_account.id
      Account::SourcePolicy.active.where(account: result.account).each do |policy|
        assert_equal external.id, policy.source_binding.fetch("external_account_id")
        assert_nil policy.source_binding.fetch("legacy_account_id")
        assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
      end
    end
  end

  test "a copied source cannot be presented as new discovery after losing its exact migration mapping" do
    with_migrated_unlinked do |connection, actor, external, _source, mapping|
      ProviderMigrationAccountBinding.where(provider_migration_mapping_id: mapping.id).delete_all
      mapping.delete

      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
        assert_raises(Setup::Conflict) { Setup.new(connection: connection, actor: actor).form(external_account_id: external.id) }
      end
      assert_nil external.reload.current_account
    end
  end

  private
    def new_attributes(changes = {})
      { "name" => "Chosen checking", "accountable_type" => "Depository", "currency" => "USD", "balance" => "12.34" }.merge(changes)
    end

    def financial_account(actor)
      actor.family.accounts.create!(owner: actor, name: "Existing financial account", currency: "USD", balance: 27,
        cash_balance: 27, accountable: Depository.new, status: "active")
    end

    def financial_snapshot(account)
      { account: account.reload.attributes.except("updated_at"),
        entries: account.entries.order(:id).map { |entry| [ entry.attributes, entry.entryable.attributes ] } }
    end

    def with_connection
      with_provider_encryption do
        family = Family.create!(name: "Native account setup")
        actor = family.users.create!(email: "native-setup-#{SecureRandom.uuid}@example.com", password: "setup-password", role: "admin")
        connection = create_provider_connection(family: family)
        yield connection, actor
      ensure
        cleanup_family(family) if family
      end
    end

    def with_migrated_unlinked
      with_connection do |empty_connection, actor|
        empty_connection.destroy!
        item = UpItem.create!(family: actor.family, name: "Copied Up", access_token: "retained-up-token")
        source = item.up_accounts.create!(account_id: "retained-up-account", name: "Unlinked checking", currency: "USD",
          current_balance: 100, raw_transactions_payload: [])
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1)
        control = nil
        30.times do
          control = copier.run_quiesced.reload
          break if control.high_water_mark["phase"] == "verified"
        end
        assert_equal "verified", control.high_water_mark["phase"]
        preparation = nil
        150.times do
          preparation = Provider::AccountData::MigrationPreparation.new(provider_key: "up", legacy_item_id: item.id,
            family: actor.family, page_size: 1).run
          break if preparation.awaiting_acceptance?
        end
        assert preparation.awaiting_acceptance?
        result = Provider::AccountData::MigrationCutover.new(provider_key: "up", legacy_item_id: item.id,
          family: actor.family, page_size: 1).call
        connection = control.provider_connection.reload
        external = connection.external_accounts.sole
        client = mock("native Up discovery")
        client.expects(:get_accounts_page).with(cursor: nil).returns(items: [ { id: source.account_id, displayName: source.name,
          accountType: "TRANSACTIONAL", balance: { currencyCode: "USD", value: "100.00" } } ], next_cursor: nil)
        Provider::Up.stubs(:new).returns(client)
        SyncJob.perform_now(Sync.find(result.sync_id))
        assert Sync.find(result.sync_id).completed?
        clear_enqueued_jobs
        mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
        yield connection, actor, external.reload, source, mapping
      end
    end

    def cleanup_family(family)
      connections = family.provider_connections.to_a
      connections.each { |connection| connection.update_columns(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil) }
      ProviderMigrationAccountBinding.where(family_id: family.id).delete_all
      observations = SourceRecord.where(family_id: family.id)
      EntrySource.where(source_record_id: observations.select(:id)).delete_all
      HoldingSource.where(source_record_id: observations.select(:id)).delete_all
      observations.delete_all
      ProviderSyncCheckpoint.where(family_id: family.id).delete_all
      IngestionBatch.where(family_id: family.id).delete_all
      ProviderSyncGeneration.where(family_id: family.id).delete_all
      Account::SourcePolicy.where(family_id: family.id).delete_all
      AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
      ProviderMigrationMapping.where(family_id: family.id).delete_all
      ProviderMigrationControl.where(family_id: family.id).delete_all
      Sync.for_family(family).destroy_all
      connections.each { |connection| connection.reload.destroy! }
      family.up_items.each do |item|
        item.up_accounts.delete_all
        item.delete
      end
      family.accounts.destroy_all
      family.users.destroy_all
      family.destroy!
    end
end
