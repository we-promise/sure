require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class AkahuItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence
  Selection = AkahuItem::Selection
  BASE_URL = Provider::Akahu::DEFAULT_BASE_URL

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end
  teardown { clear_enqueued_jobs }

  test "complete paginated discovery snapshots sources and returns an actor bound picker without financial writes" do
    with_context do |item, actor|
      first = stub_request(:get, "#{BASE_URL}/accounts").with(query: {}).to_return do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        response(items: [ row("checking") ], cursor: { next: "second" })
      end
      second = stub_request(:get, "#{BASE_URL}/accounts").with(query: { cursor: "second" })
        .to_return(response(items: [ row("savings", type: "SAVINGS") ]))
      result = nil
      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
        result = command(item, actor).discover(flow: :link_accounts)
      end
      assert_equal %w[checking savings], result.fetch(:accounts).map(&:account_id).sort
      assert result.fetch(:accounts).all? { |source| source.is_a?(AkahuAccount) && source.persisted? }
      assert_equal 2, item.reload.raw_payload.fetch("items").size
      assert selection(result, actor, :link_accounts).verify!(item)
      [ first, second ].each { |request| assert_requested request, times: 1 }
    end
  end

  test "discovery holds a real permit during HTTP and settings cannot drain it in a second session" do
    with_context do |item, actor|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      discovery do
        worker = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            Fence.with_exclusive(item) { :drained }
          rescue Fence::Busy
            :busy
          end
        end
        assert_equal :busy, Timeout.timeout(5) { worker.value }
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end
      command(item, actor).discover
      assert_equal :drained, Fence.with_exclusive(item) { :drained }
    end
  end

  test "either credential or an original source binding changing during HTTP refuses all discovery writes" do
    %i[app_token user_token link].each do |change|
      with_context do |item, actor|
        source = source_for(item)
        original_owner = financial(item, actor)
        replacement = financial(item, actor, name: "Replacement")
        link = AccountProvider.create!(account: original_owner, provider: source)
        original = source.attributes
        discovery do
          if change == :link
            link.update!(account: replacement)
          else
            item.update_columns(change => "replacement-secret")
          end
        end
        assert_raises(Fence::OwnershipChanged) { command(item, actor).discover }
        assert_equal original, source.reload.attributes
        assert_nil item.reload.raw_payload
        assert_empty original_owner.entries
        assert_empty replacement.entries
      end
    end
  end

  test "malformed or incomplete discovery never refreshes a picker or its cached sources" do
    [ { success: true }, { success: false, items: [] }, { items: [ row("checking"), row("checking") ] } ].each do |payload|
      with_context do |item, actor|
        source = source_for(item)
        original = source.attributes
        stub_request(:get, "#{BASE_URL}/accounts").to_return(response(payload))
        assert_raises(Provider::Akahu::AkahuError) { command(item, actor).discover(flow: :link_accounts) }
        assert_equal original, source.reload.attributes
        assert_nil item.reload.raw_payload
      end
    end
  end

  test "settings preserve blank credentials and invalidate selections when either credential date or timezone changes" do
    [ :app_token, :user_token, :sync_start_date, :timezone ].each do |field|
      with_context do |item, actor|
        source = source_for(item)
        selected = issued(item, actor, :link_accounts)
        command(item, actor).update_settings(name: "Renamed", app_token: "", user_token: "")
        assert_equal [ "original-app", "original-user" ], [ item.reload.app_token, item.user_token ]
        if field == :timezone
          item.family.update!(timezone: "Pacific/Auckland")
        else
          command(item, actor).update_settings(field => (field == :sync_start_date ? "2020-01-01" : "changed-token"))
        end
        assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
          assert_raises(Fence::OwnershipChanged) do
            command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected)
          end
        end
      end
    end
  end

  test "signed and decoded selections cannot cross actors actions accounts or source cache revisions" do
    with_context do |item, actor|
      source = source_for(item)
      other_actor = user(item.family, role: "admin")
      first, second = financial(item, actor), financial(item, actor, name: "Other")
      token = Selection.issue(item, actor: actor, flow: :link_existing_account, account_id: first.id)
      assert_raises(Selection::Invalid) { Selection.from_token(token, actor: other_actor, flow: :link_existing_account, account_id: first.id) }
      selected = Selection.from_token(token, actor: actor, flow: :link_existing_account, account_id: first.id)
      assert_raises(Selection::Invalid) { command(item, other_actor).link_existing_account(account_id: first.id, akahu_account_id: source.id, selection: selected) }
      assert_raises(Selection::Invalid) { command(item, actor).link_existing_account(account_id: second.id, akahu_account_id: source.id, selection: selected) }
      assert_raises(Selection::Invalid) { command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected) }
      selected = issued(item, actor, :link_accounts)
      source.update!(raw_transactions_payload: [ { "_id" => "new-cache" } ])
      assert_raises(Selection::Invalid) { command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected) }
      assert_empty item.accounts
    end
  end

  test "account setup preserves liability balances investment cash and suggested subtypes" do
    with_context do |item, actor|
      discovery(rows: [ row("credit", type: "CREDITCARD", balance: -20), row("loan", type: "LOAN", balance: -30),
        row("investment", type: "KIWISAVER", balance: 40), row("savings", type: "SAVINGS", balance: 50) ])
      result = command(item, actor).discover(flow: :complete_account_setup, setup: true)
      types = result.fetch(:accounts).to_h { |source| [ source.id, source.suggested_account_type ] }
      created = command(item, actor).complete_account_setup(account_types: types,
        selection: selection(result, actor, :complete_account_setup)).fetch(:created_accounts)
      by_type = created.index_by(&:accountable_type)
      assert_equal BigDecimal("20"), by_type.fetch("CreditCard").balance
      assert_equal "credit_card", by_type.fetch("CreditCard").accountable.subtype
      assert_equal BigDecimal("30"), by_type.fetch("Loan").balance
      assert_equal BigDecimal("40"), by_type.fetch("Investment").balance
      assert_equal BigDecimal("0"), by_type.fetch("Investment").cash_balance
      assert_equal "retirement", by_type.fetch("Investment").accountable.subtype
      assert_equal "savings", by_type.fetch("Depository").accountable.subtype
      assert created.all? { |account| account.owner_id == actor.id }
      assert_equal 4, item.account_ids.size
      assert_equal 1, item.syncs.count
    end
  end

  test "new account linking accepts the reviewed source once and requires a new picker after commit" do
    with_context do |item, actor|
      discovery
      result = command(item, actor).discover(flow: :link_accounts)
      source = result.fetch(:accounts).sole
      selected = selection(result, actor, :link_accounts)
      output = command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected)
      account = output.fetch(:created_accounts).sole
      assert_equal account.id, source.reload.account.id
      assert_equal BigDecimal("123.45"), account.balance
      assert_empty output.fetch(:already_linked_accounts)
      assert_empty output.fetch(:invalid_accounts)
      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
        assert_raises(Selection::Invalid) { command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected) }
      end
    end
  end

  test "existing account linking requires current full control rather than family admin alone" do
    with_context do |item, actor|
      source = source_for(item)
      owner = user(item.family)
      account = financial(item, owner)
      selected = issued(item, actor, :link_existing_account, account_id: account.id)
      assert_raises(Fence::OwnershipChanged) { command(item, actor).link_existing_account(account_id: account.id, akahu_account_id: source.id, selection: selected) }
      share = AccountShare.create!(account: account, user: actor, permission: "read_only")
      assert_raises(Fence::OwnershipChanged) { command(item, actor).link_existing_account(account_id: account.id, akahu_account_id: source.id, selection: selected) }
      share.update!(permission: "full_control")
      before = account.attributes
      output = command(item, actor).link_existing_account(account_id: account.id, akahu_account_id: source.id, selection: selected)
      assert_equal account.id, output.fetch(:account).id
      assert_equal before, account.reload.attributes
      assert_equal account.id, source.reload.account.id
    end
  end

  test "demotion after picker issuance refuses mutation and creation rechecks the actor" do
    with_context do |item, actor|
      source = source_for(item)
      selected = issued(item, actor, :link_accounts)
      actor.update!(role: "member")
      assert_no_difference [ "AkahuItem.count", "Account.count", "AccountProvider.count", "Sync.count" ] do
        assert_raises(Fence::OwnershipChanged) { command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected) }
        assert_raises(Fence::OwnershipChanged) do
          AkahuItem::Lifecycle.create(family: item.family, actor: actor, attributes: { name: "New", app_token: "app", user_token: "user" })
        end
      end
    end
  end

  test "setup is atomic when a later account link fails" do
    with_context do |item, actor|
      first, second = source_for(item), source_for(item, remote: "second")
      selected = issued(item, actor, :complete_account_setup)
      last_id = [ first.id, second.id ].sort.last
      failure = ->(link) { raise IOError, "private callback failure" if link.provider_id == last_id }
      AccountProvider.set_callback(:create, :after, failure)
      begin
        assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
          assert_raises(IOError) do
            command(item, actor).complete_account_setup(account_types: { first.id => "Depository", second.id => "Depository" }, selection: selected)
          end
        end
      ensure
        AccountProvider.skip_callback(:create, :after, failure)
      end
    end
  end

  test "native transitional and scheduled owners refuse management before remote requests" do
    %w[active quiescing scheduled].each do |state|
      with_context do |item, actor|
        source = source_for(item)
        selected = issued(item, actor, :link_accounts)
        if state == "scheduled"
          item.update!(scheduled_for_deletion: true)
        else
          ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem", legacy_id: item.id, state: state)
        end
        calls = [ -> { command(item, actor).discover }, -> { command(item, actor).update_settings(name: "Changed") },
          -> { command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected) },
          -> { command(item, actor).disconnect }, -> { AkahuItem::Lifecycle.schedule_destroy!(item) } ]
        before = item.reload.attributes
        calls.each { |call| assert_raises(Fence::OwnershipChanged, &call) }
        assert_equal before, item.reload.attributes
        assert_not_requested :get, /api\.akahu\.io/
      end
    end
  end

  test "a held visible Sync refuses account setup without blocking or leaving new financial rows" do
    with_context do |item, actor|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      source = source_for(item)
      selected = issued(item, actor, :link_accounts)
      sync = item.syncs.create!
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Sync.transaction do
            Sync.where(id: sync.id).lock("FOR UPDATE").load
            ready << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { ready.pop }
      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
        Timeout.timeout(5) do
          assert_raises(Fence::Busy) do
            command(item, actor).link_accounts(account_ids: [ source.id ], account_type: "Depository", selection: selected)
          end
        end
      end
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "disconnect detaches only its sources and dispatches destruction after the permit and transaction end" do
    with_context do |item, actor|
      account = financial(item, actor)
      source = source_for(item)
      link = AccountProvider.create!(account: account, provider: source)
      sibling = item.family.akahu_items.create!(name: "Sibling", app_token: "app", user_token: "user")
      other = AccountProvider.create!(account: financial(item, actor, name: "Other"), provider: source_for(sibling))
      before = account.attributes
      dry = command(item, actor).disconnect(dry_run: true)
      assert_equal [ link.id ], dry.sole.fetch(:provider_link_ids)
      assert AccountProvider.exists?(link.id)
      DestroyJob.expects(:perform_later).with do |current|
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal 0, ApplicationRecord.connection.open_transactions
        current.id == item.id && current.scheduled_for_deletion?
      end
      command(item, actor).disconnect
      assert_not AccountProvider.exists?(link.id)
      assert AccountProvider.exists?(other.id)
      assert_equal before, account.reload.attributes
    end
  end

  test "disconnect rechecks each financial permission and rolls back every link on callback failure" do
    with_context do |item, actor|
      owner = user(item.family)
      first, second = source_for(item), source_for(item, remote: "second")
      account = financial(item, owner)
      links = [ AccountProvider.create!(account: account, provider: first),
        AccountProvider.create!(account: financial(item, actor), provider: second) ]
      DestroyJob.expects(:perform_later).never
      assert_raises(Fence::OwnershipChanged) { command(item, actor).disconnect }
      AccountShare.create!(account: account, user: actor, permission: "full_control")
      last_id = links.map(&:id).sort.last
      failure = ->(link) { raise IOError, "private unlink failure" if link.id == last_id }
      AccountProvider.set_callback(:destroy, :after, failure)
      begin
        assert_raises(IOError) { command(item, actor).disconnect }
      ensure
        AccountProvider.skip_callback(:destroy, :after, failure)
      end
      assert_equal 2, AccountProvider.where(id: links.map(&:id)).count
      assert_not item.reload.scheduled_for_deletion?
    end
  end

  test "retained source policies refuse unlink and direct deletion scheduling refuses any live link" do
    with_context do |item, actor|
      account = financial(item, actor)
      source = source_for(item)
      link = AccountProvider.create!(account: account, provider: source)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      before = [ account.attributes, link.attributes, policy.attributes ]
      DestroyJob.expects(:perform_later).never
      assert_raises(Fence::OwnershipChanged) { command(item, actor).disconnect }
      assert_raises(Fence::OwnershipChanged) { AkahuItem::Lifecycle.schedule_destroy!(item) }
      assert_equal before, [ account.reload.attributes, link.reload.attributes, policy.reload.attributes ]
      assert_not item.reload.scheduled_for_deletion?
    end
  end

  test "direct deletion scheduling drains its unlinked owner and dispatches after release" do
    with_context do |item, _actor|
      source_for(item)
      DestroyJob.expects(:perform_later).with do |current|
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal 0, ApplicationRecord.connection.open_transactions
        current.id == item.id
      end
      AkahuItem::Lifecycle.schedule_destroy!(item)
      assert item.reload.scheduled_for_deletion?
    end
  end

  test "a shared external attachment cannot be detached through legacy disconnect" do
    with_context do |item, actor|
      source = source_for(item)
      connection = create_provider_connection(family: item.family, provider_key: "akahu",
        credentials: { "app_token" => "native-app", "user_token" => "native-user" })
      external = connection.external_accounts.create!(family: item.family, provider_key: "akahu", external_id: source.account_id,
        identity_namespace: "account", name: "Shared source")
      account = financial(item, actor)
      link = AccountProvider.create!(account: account, provider: source, external_account: external)
      before = link.attributes
      DestroyJob.expects(:perform_later).never
      assert_raises(Fence::OwnershipChanged) { command(item, actor).disconnect }
      assert_equal before, link.reload.attributes
      assert_not item.reload.scheduled_for_deletion?
    end
  end

  private
    def command(item, actor)
      AkahuItem::Lifecycle.new(item: item, actor: actor)
    end

    def selection(result, actor, flow, account_id: nil)
      Selection.from_token(result.fetch(:selection_token), actor: actor, flow: flow, account_id: account_id)
    end

    def issued(item, actor, flow, account_id: nil)
      Selection.from_token(Selection.issue(item, actor: actor, flow: flow, account_id: account_id),
        actor: actor, flow: flow, account_id: account_id)
    end

    def row(remote = "checking", type: "CHECKING", balance: 123.45)
      { _id: remote, name: remote.titleize, type: type, status: "ACTIVE", balance: { current: balance, currency: "NZD" } }
    end

    def response(payload = nil, **fields)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: (payload || fields).to_json }
    end

    def discovery(rows: [ row ], &during_request)
      stub_request(:get, "#{BASE_URL}/accounts").to_return do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        during_request&.call
        response(items: rows)
      end
    end

    def source_for(item, remote: "checking")
      item.akahu_accounts.create!(account_id: remote, name: remote.titleize, currency: "NZD", account_type: "CHECKING",
        current_balance: 123.45, raw_payload: row(remote), raw_transactions_payload: [])
    end

    def financial(item, owner, name: "Manual")
      item.family.accounts.create!(owner: owner, name: name, currency: "NZD", balance: 9, accountable: Depository.new)
    end

    def user(family, role: "member")
      family.users.create!(email: "akahu-lifecycle-#{SecureRandom.uuid}@example.com", password: "akahu-test-password", role: role)
    end

    def with_context
      WebMock.reset!
      with_provider_encryption do
        family = Family.create!(name: "Akahu lifecycle", timezone: "UTC")
        actor = user(family, role: "admin")
        item = family.akahu_items.create!(name: "Akahu", app_token: "original-app", user_token: "original-user")
        yield item, actor
      ensure
        if family
          ids = family.accounts.pluck(:id)
          Account::SourcePolicy.where(family_id: family.id).delete_all
          Holding.where(account_id: ids).destroy_all
          AccountProvider.where(account_id: ids).delete_all
          family.accounts.each(&:destroy!)
          ProviderMigrationControl.where(family_id: family.id).delete_all
          family.provider_connections.each(&:destroy!)
          item_ids = family.akahu_items.pluck(:id)
          Sync.where(syncable_type: "AkahuItem", syncable_id: item_ids).destroy_all
          AkahuAccount.where(akahu_item_id: item_ids).delete_all
          AkahuItem.where(id: item_ids).delete_all
          Session.where(user_id: family.users.select(:id)).delete_all
          family.users.delete_all
          family.destroy!
        end
        clear_enqueued_jobs
      end
    end
end
