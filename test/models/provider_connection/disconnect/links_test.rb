require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"
require_relative "../../../support/account_sync_input_test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class ProviderConnection::Disconnect::LinksTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include AccountSyncInputTestHelper
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Links = ProviderConnection::Disconnect::Links
  Context = Data.define(:family, :actor, :accounts, :connection, :externals, :links, :other_connection, :other_link)

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Account.any_instance.stubs(:sync_later)
  end
  teardown { clear_enqueued_jobs }

  test "detaching two accounts preserves the other provider and every financial and source record" do
    with_sources do |fixture|
      observation, batch = publish_original(fixture)
      entry = observation.entry
      entry.update!(name: "My description", import_locked: true, user_modified: true)
      own_holding = holding(fixture.accounts.first, fixture.links.first, "own")
      other_holding = holding(fixture.accounts.first, fixture.other_link, "other", date: Date.current - 1)
      before_entries = fixture.accounts.map { |account| account.entries.order(:id).map(&:attributes) }
      before_accounts = fixture.accounts.map { |account| account.reload.attributes }
      own_values, other_values = own_holding.attributes.except("account_provider_id"), other_holding.attributes
      original_observation, original_mapping, original_batch = observation.attributes, observation.entry_source.attributes, batch.reload.attributes
      other_link = fixture.other_link.reload.attributes
      policies = Account::SourcePolicy.where(family: fixture.family).order(:id).map(&:attributes)

      command(fixture).with_locked do |context|
        assert_equal fixture.connection.id, context.connection.id
        assert_equal fixture.accounts.map(&:id).sort, context.accounts.map(&:id)
        assert context.binding.frozen?
        assert_equal context.binding, JSON.parse(JSON.generate(context.binding))
        assert context.detach!
      end

      assert_empty AccountProvider.where(id: fixture.links.map(&:id))
      assert_equal other_link, fixture.other_link.reload.attributes
      assert_equal before_accounts, fixture.accounts.map { |account| account.reload.attributes }
      assert_equal before_entries, fixture.accounts.map { |account| account.entries.order(:id).map(&:attributes) }
      assert_equal own_values, own_holding.reload.attributes.except("account_provider_id")
      assert_nil own_holding.account_provider_id
      assert_equal other_values, other_holding.reload.attributes
      assert_equal original_observation, observation.reload.attributes
      assert_equal original_mapping, observation.entry_source.reload.attributes
      assert_equal original_batch, batch.reload.attributes
      policies.each do |row|
        policy = Account::SourcePolicy.find(row.fetch("id"))
        expected = fixture.links.map(&:id).include?(row.fetch("account_provider_id")) ? false : row.fetch("active")
        assert_equal expected, policy.active?
        assert_equal row.except("active", "updated_at"), policy.attributes.except("active", "updated_at")
      end
      assert_nil Account::SourcePolicy.active.find_by(account: fixture.accounts.first, resource: "balances")
      assert_nil fixture.accounts.first.reload.provider
    end
  end

  test "caller failure rolls back the complete multi-account detach" do
    with_sources do |fixture|
      own_holding = holding(fixture.accounts.last, fixture.links.last, "rollback")
      before = graph(fixture)

      assert_raises(IOError) do
        command(fixture).with_locked do |context|
          context.detach!
          raise IOError, "failed final connection receipt"
        end
      end

      assert_equal before, graph(fixture)
      assert_equal fixture.links.last.id, own_holding.reload.account_provider_id
    end
  end

  test "detach cannot run before or after its admitted transaction or twice inside it" do
    with_sources do |fixture|
      access = command(fixture)
      assert_raises(Links::Conflict) { access.detach! }
      retained_context = nil
      access.with_locked { |context| retained_context = context }
      assert_raises(Links::Conflict) { retained_context.detach! }
      access.with_locked do |context|
        assert_raises(Links::Conflict) { retained_context.detach! }
        assert context.detach!
        assert_raises(Links::Conflict) { context.detach! }
      end
      assert_raises(Links::Conflict) { access.detach! }
    end
  end

  test "a copied native Plaid direct link clears only its own foreign key and preserves legacy SimpleFIN" do
    family = families(:dylan_family)
    timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
    with_identity_source(provider_key: "plaid") do |fixture|
      other_item = SimplefinItem.create!(family: family, name: "Other legacy source", access_url: "https://example.com/other-source")
      other_source = other_item.simplefin_accounts.create!(account_id: "other-source", name: "Other source", currency: "USD", current_balance: 0)
      other_link = AccountProvider.create!(account: fixture.account, provider: other_source)
      begin
        fixture.account.update!(plaid_account: fixture.source, simplefin_account: other_source)
        # Exercise routing under test-only native ownership using actual copied
        # mappings; this is not a signed cutover or activation acceptance test.
        fixture.control.update!(state: "active", writer_epoch: 1)
        fixture.control.provider_connection.update!(status: "good", writer_epoch: 1)
        original_archives = fixture.control.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text"))

        access = Links.new(connection_id: fixture.control.provider_connection_id, family_id: family.id,
          actor_id: fixture.account.owner_id)
        access.with_locked(&:detach!)

        assert_nil fixture.account.reload.plaid_account_id
        assert_equal other_source.id, fixture.account.simplefin_account_id
        refute AccountProvider.exists?(fixture.link.id)
        assert AccountProvider.exists?(other_link.id)
        assert PlaidAccount.exists?(fixture.source.id)
        assert SimplefinAccount.exists?(other_source.id)
        assert_equal original_archives, fixture.control.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text"))
        ApplicationRecord.transaction { assert access.assert_detached! }
        reintroduced = AccountProvider.create!(account: fixture.account, provider: fixture.source)
        assert_raises(Links::Conflict) { access.with_locked { flunk "Legacy-only link needs disposition" } }
        ApplicationRecord.transaction do
          assert_raises(Links::Conflict) { access.assert_detached! }
        end
        reintroduced.delete
        uncopied = fixture.item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Unmapped direct source", currency: "USD", plaid_type: "depository")
        fixture.account.update_columns(plaid_account_id: uncopied.id)
        assert_raises(Links::Conflict) { access.with_locked { flunk "Unmapped direct source needs disposition" } }
        ApplicationRecord.transaction do
          assert_raises(Links::Conflict) { access.assert_detached! }
        end
      ensure
        fixture.account.update_columns(plaid_account_id: nil, simplefin_account_id: nil)
        AccountProvider.where(id: other_link.id).delete_all
        other_source.delete
        other_item.delete
      end
    end
  ensure
    Family.where(id: family.id).update_all(timestamps) if family && timestamps
  end

  test "family admin needs owner or full control on every affected account" do
    with_sources do |fixture|
      owner = fixture.family.users.create!(email: "other-owner-#{SecureRandom.uuid}@example.com", password: "disconnect-password", role: "member")
      account = fixture.accounts.last
      account.update!(owner: owner)
      AccountShare.where(account: account, user: fixture.actor).delete_all
      before = graph(fixture)

      assert_raises(Links::Conflict) { command(fixture).with_locked { flunk "Admin alone cannot manage a private account" } }
      assert_equal before, graph(fixture)
      share = account.share_with!(fixture.actor, permission: "read_write")
      assert_raises(Links::Conflict) { command(fixture).with_locked { flunk "Read-write access cannot disconnect" } }
      share.update!(permission: "full_control")
      command(fixture).with_locked(&:detach!)
      assert_empty AccountProvider.where(id: fixture.links.map(&:id))
    end
  end

  test "permission account name or newly added source drift invalidates captured admission" do
    [ :permission, :account_name, :new_account ].each do |change|
      with_sources do |fixture|
        access = changing_inventory(fixture) do
          if change == :permission
            fixture.actor.update_columns(active: false)
          elsif change == :account_name
            fixture.accounts.first.update_columns(name: "Changed review name")
          else
            account = fixture.family.accounts.create!(owner: fixture.actor, name: "New affected account", currency: "USD", balance: 0, accountable: Depository.new)
            external = create_external_account(fixture.connection)
            AccountProvider.create!(account: account, external_account: external)
          end
        end
        assert_raises(Links::Conflict) { access.with_locked { flunk "Changed graph requires a new review" } }
        assert_equal fixture.links.size, AccountProvider.where(id: fixture.links.map(&:id)).count
      end
    end
  end

  test "incomplete Account work and retained native lease fields refuse without detaching" do
    [ :account_sync, :expired_lease ].each do |busy|
      with_sources do |fixture|
        if busy == :account_sync
          pending = fixture.accounts.first.syncs.create!(status: "pending")
        else
          fixture.other_connection.update!(lease_owner: "unresolved-owner", lease_expires_at: 1.hour.ago)
        end
        before = graph(fixture)
        assert_raises(Links::Busy) { command(fixture).with_locked { flunk "Outstanding work must finish first" } }
        assert_equal before, graph(fixture)
      ensure
        pending&.delete
        fixture.other_connection.update_columns(lease_owner: nil, lease_expires_at: nil) if fixture
      end
    end
  end

  test "another session's source lock refuses and a later attempt releases all admission resources" do
    with_sources do |fixture|
      with_row_lock(fixture.other_link) do
        assert_raises(Links::Busy) { command(fixture).with_locked { flunk "Busy shared source cannot detach" } }
        assert_equal fixture.links.size, AccountProvider.where(id: fixture.links.map(&:id)).count
      end
      command(fixture).with_locked(&:detach!)
      assert_nil ActiveSupport::IsolatedExecutionState[Provider::AccountData::LegacyWriterFence::CONTEXT_KEY]
      assert_equal 0, ApplicationRecord.connection.open_transactions
    end
  end

  test "legacy companion permit is held before publication and the companion source survives" do
    with_sources do |fixture|
      item = PlaidItem.create!(family: fixture.family, name: "Legacy companion", access_token: "private-companion",
        plaid_id: SecureRandom.uuid, plaid_region: "eu")
      source = item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Legacy account", currency: "USD", plaid_type: "depository")
      target = create_provider_connection(family: fixture.family, provider_key: "brex")
      external = create_external_account(target)
      native = AccountProvider.create!(account: fixture.accounts.last, external_account: external)
      legacy = AccountProvider.create!(account: fixture.accounts.last, provider: source)
      begin
        Links.new(connection_id: target.id, family_id: fixture.family.id, actor_id: fixture.actor.id).with_locked do |context|
          held = ActiveSupport::IsolatedExecutionState[Provider::AccountData::LegacyWriterFence::CONTEXT_KEY]
          assert held
          assert_operator ApplicationRecord.connection.open_transactions, :>, 0
          context.detach!
        end
        refute AccountProvider.exists?(native.id)
        assert AccountProvider.exists?(legacy.id)
        assert PlaidAccount.exists?(source.id)
        assert PlaidItem.exists?(item.id)
      ensure
        AccountProvider.where(id: legacy.id).delete_all
        source.delete
        item.delete
      end
    end
  end

  test "selected historical pointer is preserved for another source and cleared only for its original source" do
    actor = created_actor = nil
    with_account_input do
      actor = @account.owner
      unless actor
        actor = @account.family.users.create!(email: "input-owner-#{SecureRandom.uuid}@example.com", password: "disconnect-password", role: "admin")
        created_actor = actor
        @account.update!(owner: actor)
      end
      child = enqueue_account_handoff
      child.update!(status: "completed", completed_at: Time.current)
      @provider_sync.update!(status: "completed", completed_at: Time.current)
      pointer = Account::SyncSource.find_by!(account: @account)
      input = pointer.account_sync_input
      input_bytes = Account::SyncInput.where(id: input.id).pick(Arel.sql("payload::text"))
      other = create_provider_connection(family: @account.family, provider_key: "up")
      external = create_external_account(other)
      other_link = AccountProvider.create!(account: @account, external_account: external)
      begin
        Links.new(connection_id: other.id, family_id: @account.family_id, actor_id: actor.id).with_locked(&:detach!)
        assert_equal input.id, pointer.reload.account_sync_input_id
        Links.new(connection_id: @connection.id, family_id: @account.family_id, actor_id: actor.id).with_locked(&:detach!)
        refute Account::SyncSource.exists?(pointer.id)
        assert Account::SyncInput.exists?(input.id)
        assert_equal input_bytes, Account::SyncInput.where(id: input.id).pick(Arel.sql("payload::text"))
        assert Sync.exists?(child.id)
      ensure
        AccountProvider.where(id: other_link.id).delete_all
        other.destroy!
      end
    end
  ensure
    created_actor&.destroy!
  end

  private
    def command(fixture)
      Links.new(connection_id: fixture.connection.id, family_id: fixture.family.id, actor_id: fixture.actor.id)
    end

    def graph(fixture)
      { accounts: fixture.accounts.map { |account| account.reload.attributes },
        links: AccountProvider.where(account_id: fixture.accounts.map(&:id)).order(:id).map(&:attributes),
        policies: Account::SourcePolicy.where(family: fixture.family).order(:id).map(&:attributes),
        holdings: Holding.where(account_id: fixture.accounts.map(&:id)).order(:id).map(&:attributes) }
    end

    def publish_original(fixture)
      policy = Account::SourcePolicy.active.find_by!(account: fixture.accounts.first, resource: "transactions")
      record = Ingestion::Record.transaction(external_id: "up_original", amount: BigDecimal("12.50"), currency: "USD", date: Date.current,
        name: "Original financial event", pending: false)
      page = Provider::AccountData::Page.new(records: [ record ], complete: true)
      batch = create_provider_batch(fixture.connection, external_account: fixture.externals.first,
        stream: "transactions", scope_key: "account:#{fixture.externals.first.id}", source_policy_version: policy.id,
        mode: page.mode, payload: Ingestion::Codec.dump(page))
      ApplicationRecord.transaction do
        Ingestion::LedgerWriter.new(external_account: fixture.externals.first, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: Time.current)
      end
      batch.sync.update!(status: "completed", completed_at: Time.current)
      [ SourceRecord.find_by!(external_account: fixture.externals.first, external_id: "up_original"), batch ]
    end

    def holding(account, link, external_id, date: Date.current)
      account.holdings.create!(security: securities(:aapl), account_provider: link, qty: 2, price: 10, amount: 20,
        currency: "USD", date: date, external_id: external_id)
    end

    def changing_inventory(fixture, &change)
      Class.new(Links) do
        define_method(:initialize) do |**attributes|
          super(**attributes)
          @change_once = change
        end
        private
          def snapshot
            captured = super
            change = @change_once
            @change_once = nil
            change&.call
            captured
          end
      end.new(connection_id: fixture.connection.id, family_id: fixture.family.id, actor_id: fixture.actor.id)
    end

    def with_row_lock(record)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          record.class.transaction do
            record.class.where(id: record.id).select(:id).lock("FOR UPDATE").first!
            entered << true
            release.pop
          end
        end
      rescue StandardError => error
        entered << error
        raise
      end
      worker.report_on_exception = false
      observed = Timeout.timeout(5) { entered.pop }
      raise observed if observed.is_a?(Exception)
      yield
    ensure
      release << true if release
      begin
        Timeout.timeout(5) { worker.value } if worker
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end
    end

    def with_sources
      with_provider_encryption do
        family = Family.create!(name: "Source-scoped disconnect")
        actor = family.users.create!(email: "disconnect-#{SecureRandom.uuid}@example.com", password: "disconnect-password", role: "admin")
        accounts = 2.times.map do |number|
          family.accounts.create!(owner: actor, name: "Financial account #{number}", currency: "USD", balance: 100, accountable: Depository.new)
        end
        connection = create_provider_connection(family: family)
        externals = accounts.map { create_external_account(connection) }
        links = accounts.zip(externals).map { |account, external| AccountProvider.create!(account: account, external_account: external) }
        accounts.zip(links).each do |account, link|
          Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[balances transactions])
        end
        other_connection = create_provider_connection(family: family, provider_key: "mercury")
        other_external = create_external_account(other_connection)
        other_link = AccountProvider.create!(account: accounts.first, external_account: other_external)
        yield Context.new(family: family, actor: actor, accounts: accounts, connection: connection,
          externals: externals, links: links, other_connection: other_connection, other_link: other_link)
      ensure
        cleanup_family(family) if family
        clear_enqueued_jobs
      end
    end

    def cleanup_family(family)
      accounts = Account.where(family_id: family.id)
      Account::SyncSource.where(family_id: family.id).delete_all
      Sync.where(syncable_type: "Account", syncable_id: accounts.select(:id)).delete_all
      EntrySource.where(family_id: family.id).delete_all
      HoldingSource.where(family_id: family.id).delete_all
      SourceRecord.where(family_id: family.id).delete_all
      Account::SourcePolicy.where(family_id: family.id).delete_all
      Holding.where(account_id: accounts.select(:id)).delete_all
      AccountProvider.where(account_id: accounts.select(:id)).delete_all
      ProviderMigrationAccountBinding.where(family_id: family.id).delete_all
      ProviderSyncCheckpoint.where(family_id: family.id).delete_all
      IngestionBatch.where(family_id: family.id).delete_all
      ProviderMigrationMapping.where(family_id: family.id).delete_all
      ProviderMigrationControl.where(family_id: family.id).delete_all
      connections = ProviderConnection.where(family_id: family.id)
      Sync.where(syncable_type: "ProviderConnection", syncable_id: connections.select(:id)).delete_all
      connections.each(&:destroy!)
      accounts.each(&:destroy!)
      family.users.each(&:destroy!)
      family.destroy!
    end
end
