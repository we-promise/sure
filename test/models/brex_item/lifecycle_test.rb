require "test_helper"
require "timeout"
require_relative "../../support/brex_lifecycle_test_helper"

class BrexItem::LifecycleTest < ActiveSupport::TestCase
  include BrexLifecycleTestHelper
  self.use_transactional_tests = false
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    SyncJob.stubs(:perform_later)
    DestroyJob.stubs(:perform_later)
    DebugLogEntry.stubs(:capture)
  end

  test "discovery and reviewed new-account linking preserve legacy behavior without HTTP in a transaction" do
    with_brex_context do |item, actor|
      brex_provider
      command = brex_command(item, actor)
      discovery = command.discover(flow: :link_accounts)
      assert_equal [ "checking-1" ], discovery[:accounts].map { |row| row[:id] }
      selection = brex_selection(discovery, flow: :link_accounts)
      result = command.link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: selection)
      account = result[:created_accounts].sole
      assert_equal [ item.family_id, actor.id, "Business checking", "USD", BigDecimal("0") ],
        account.attributes.values_at("family_id", "owner_id", "name", "currency", "balance")
      assert_equal account.id, item.brex_accounts.sole.current_account.id
      assert_equal 1, item.syncs.count
      repeated = command.link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: selection)
      assert_empty repeated[:created_accounts]
      assert_equal [ "Business checking" ], repeated[:already_linked_accounts]
    end
  end

  test "setup discovery persists sources and completion preserves source balance and subtype" do
    with_brex_context do |item, actor|
      brex_provider
      command = brex_command(item, actor)
      discovery = command.discover(flow: :complete_account_setup, setup: true)
      source = item.brex_accounts.sole
      result = command.complete_account_setup(account_types: { source.id => "Depository" }, account_subtypes: { source.id => "checking" },
        selection: brex_selection(discovery, flow: :complete_account_setup))
      assert_equal BigDecimal("125"), result[:created_accounts].sole.balance
      assert_equal "checking", result[:created_accounts].sole.accountable.subtype
      refute command.discover(flow: :complete_account_setup, setup: true)[:cached]
    end
  end

  test "existing account linking preserves financial data and exact target permission" do
    with_brex_context do |item, actor|
      brex_provider
      account = brex_financial(item, actor)
      original = account.attributes
      command = brex_command(item, actor)
      discovery = command.discover(flow: :link_existing_account, account_id: account.id)
      selection = brex_selection(discovery, flow: :link_existing_account, account_id: account.id)
      result = command.link_existing_account(account_id: account.id, brex_account_id: "checking-1", selection: selection)
      assert_equal account.id, result[:account].id
      assert_equal original, account.reload.attributes
      assert_equal "checking-1", account.account_providers.sole.provider.account_id
    end
  end

  test "retained form cannot change flow item family target or credentials" do
    with_brex_context do |item, actor|
      brex_provider
      result = brex_command(item, actor).discover(flow: :link_accounts)
      token = result[:selection_token]
      assert_raises(BrexItem::Selection::Invalid) { BrexItem::Selection.from_token(nil, flow: :link_accounts) }
      assert_raises(BrexItem::Selection::Invalid) { BrexItem::Selection.from_token(token + "tampered", flow: :link_accounts) }
      assert_raises(BrexItem::Selection::Invalid) { BrexItem::Selection.from_token(token, flow: :complete_account_setup) }
      assert_raises(BrexItem::Selection::Invalid) { BrexItem::Selection.from_token(token, flow: :link_accounts, account_id: SecureRandom.uuid) }
      selection = brex_selection(result, flow: :link_accounts)
      other = item.family.brex_items.create!(name: "Other", token: "other")
      assert_raises(Fence::OwnershipChanged) do
        brex_command(other, actor).link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: selection)
      end
      item.update!(token: "rotated")
      Provider::Brex.expects(:new).never
      assert_raises(Fence::OwnershipChanged) do
        brex_command(item, actor).link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: selection)
      end
      assert_empty item.family.accounts
    end
  end

  test "credential changes during discovery cannot cache or publish the old response" do
    with_brex_context do |item, actor|
      old_key = BrexItem::Selection.cache_key(item)
      brex_provider { BrexItem.where(id: item.id).update_all(token: "rotated-during-read") }
      assert_raises(Fence::OwnershipChanged) { brex_command(item, actor).discover(flow: :complete_account_setup, setup: true) }
      assert_nil Rails.cache.read(old_key)
      assert_empty item.brex_accounts
      assert_empty item.family.accounts
    end
  end

  test "settings use the fresh item and invalidate only the old credential-bound cache" do
    with_brex_context do |item, actor|
      stale = BrexItem.find(item.id)
      item.update!(token: "already-rotated")
      old_key = BrexItem::Selection.cache_key(item)
      Rails.cache.write(old_key, brex_rows)
      current = brex_command(stale, actor).update_settings(name: "Renamed")
      assert_equal "already-rotated", current.token
      assert Rails.cache.exist?(old_key)
      brex_command(stale, actor).update_settings(token: "next-token")
      assert_nil Rails.cache.read(old_key)
      assert_equal "next-token", item.reload.token
    end
  end

  test "credential updates drain active legacy readers before changing the token" do
    with_brex_context do |item, actor|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        Fence.with_item(item) do
          ready << true
          release.pop
        end
      rescue Exception => error
        ready << error
        raise
      end
      begin
        observed = Timeout.timeout(5) { ready.pop }
        raise observed if observed.is_a?(Exception)
        assert_raises(Fence::Busy) { brex_command(item, actor).update_settings(token: "after-drain") }
        assert_equal "original-token", item.reload.token
      ensure
        release << true
        Timeout.timeout(5) { worker.value }
      end
      assert_equal "after-drain", brex_command(item, actor).update_settings(token: "after-drain").token
    end
  end

  test "a discovery response without accounts cannot become a cached or signed empty inventory" do
    with_brex_context do |item, actor|
      provider = mock("partial Brex response")
      provider.expects(:get_accounts).returns({})
      Provider::Brex.stubs(:new).returns(provider)
      assert_raises(Fence::OwnershipChanged) { brex_command(item, actor).discover(flow: :complete_account_setup, setup: true) }
      assert_nil Rails.cache.read(BrexItem::Selection.cache_key(item))
      assert_empty item.brex_accounts
    end
  end

  test "all legacy browser and direct model mutations refuse transitional and native ownership" do
    with_brex_context do |item, actor|
      selection = BrexItem::Selection.from_token(BrexItem::Selection.issue(item, flow: :link_accounts), flow: :link_accounts)
      setup = BrexItem::Selection.from_token(BrexItem::Selection.issue(item, flow: :complete_account_setup), flow: :complete_account_setup)
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "brex", legacy_type: "BrexItem", legacy_id: item.id)
      Provider::Brex.expects(:new).never
      %w[quiescing active retired rollback_pending].each do |state|
        control.update!(state: state)
        operations = [ -> { brex_command(item, actor).discover }, -> { brex_command(item, actor).update_settings(name: "changed") },
          -> { brex_command(item, actor).disconnect }, -> { item.destroy_later }, -> { item.unlink_all!(actor: actor) },
          -> { brex_command(item, actor).link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: selection) },
          -> { brex_command(item, actor).complete_account_setup(account_types: {}, account_subtypes: {}, selection: setup) } ]
        assert_no_difference [ "Sync.count", "Account.count", "BrexAccount.count" ] do
          operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
        end
        assert_not item.reload.scheduled_for_deletion?
        assert_equal "Brex", item.name
      end
    end
  end

  test "fresh actor revocation and financial read-only access refuse before discovery" do
    with_brex_context do |item, actor|
      command = brex_command(item, actor)
      User.where(id: actor.id).update_all(active: false)
      Provider::Brex.expects(:new).never
      assert_raises(Fence::OwnershipChanged) { command.discover }
      User.where(id: actor.id).update_all(active: true)
      owner = item.family.users.create!(email: "brex-owner-#{SecureRandom.uuid}@example.com", password: "brex-test-password", role: "member")
      account = brex_financial(item, owner)
      account.account_shares.where(user_id: actor.id).delete_all
      account.share_with!(actor, permission: "read_only")
      assert_raises(Fence::OwnershipChanged) { command.discover(flow: :link_existing_account, account_id: account.id) }
    end
  end

  test "a source from another item cannot be completed by a valid setup form" do
    with_brex_context do |item, actor|
      other = item.family.brex_items.create!(name: "Other", token: "other")
      source = other.brex_accounts.create!(account_id: "other-remote", name: "Other", currency: "USD")
      selection = BrexItem::Selection.from_token(BrexItem::Selection.issue(item, flow: :complete_account_setup), flow: :complete_account_setup)
      assert_no_difference "Account.count" do
        assert_raises(Fence::OwnershipChanged) do
          brex_command(item, actor).complete_account_setup(account_types: { source.id => "Depository" }, account_subtypes: {}, selection: selection)
        end
      end
    end
  end

  test "link publication rolls back newly created account and source when link callback fails after SQL" do
    with_brex_context do |item, actor|
      brex_provider
      command = brex_command(item, actor)
      selection = brex_selection(command.discover(flow: :link_accounts), flow: :link_accounts)
      callback = ->(_link) { raise IOError, "Simulated link callback failure" }
      AccountProvider.set_callback(:create, :after, callback)
      begin
        assert_no_difference [ "Account.count", "Depository.count", "AccountProvider.count", "BrexAccount.count", "Sync.count" ] do
          assert_raises(IOError) { command.link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: selection) }
        end
      ensure
        AccountProvider.skip_callback(:create, :after, callback)
      end
    end
  end

  test "ordinary disconnect unlinks only this item and schedules deletion atomically" do
    with_brex_context do |item, actor|
      account = brex_financial(item, actor)
      source = item.brex_accounts.create!(account_id: "checking-1", name: "Checking", currency: "USD")
      link = AccountProvider.create!(account: account, provider: source)
      other = item.family.brex_items.create!(name: "Other", token: "other")
      sibling = other.brex_accounts.create!(account_id: "sibling", name: "Sibling", currency: "USD")
      sibling_link = AccountProvider.create!(account: brex_financial(item, actor, name: "Sibling"), provider: sibling)
      DestroyJob.expects(:perform_later).with do |current|
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal 0, ApplicationRecord.connection.open_transactions
        current.id == item.id && current.scheduled_for_deletion?
      end
      assert brex_command(item, actor).disconnect
      assert_not AccountProvider.exists?(link.id)
      assert AccountProvider.exists?(sibling_link.id)
      assert item.reload.scheduled_for_deletion?
      assert_equal BigDecimal("9"), account.reload.balance
    end
  end

  test "failed disconnect callback restores all links and leaves deletion unscheduled" do
    with_brex_context do |item, actor|
      account = brex_financial(item, actor)
      source = item.brex_accounts.create!(account_id: "checking-1", name: "Checking", currency: "USD")
      link = AccountProvider.create!(account: account, provider: source)
      callback = ->(_link) { raise IOError, "Simulated unlink failure" }
      AccountProvider.set_callback(:destroy, :after, callback)
      begin
        DestroyJob.expects(:perform_later).never
        assert_raises(IOError) { brex_command(item, actor).disconnect }
      ensure
        AccountProvider.skip_callback(:destroy, :after, callback)
      end
      assert AccountProvider.exists?(link.id)
      assert_not item.reload.scheduled_for_deletion?
    end
  end

  test "discovery retains the actual drain permit while HTTP executes" do
    with_brex_context do |item, actor|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      brex_provider do
        worker = Thread.new do
          Fence.with_exclusive(item) { :drained }
        rescue Fence::Busy
          :busy
        end
        assert_equal :busy, Timeout.timeout(5) { worker.value }
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end
      brex_command(item, actor).discover
      assert_equal :drained, Fence.with_exclusive(item) { :drained }
    end
  end

  test "decoded selections cannot cross lifecycle actions or financial targets" do
    with_brex_context do |item, actor|
      first = brex_financial(item, actor)
      second = brex_financial(item, actor, name: "Another account")
      token = BrexItem::Selection.issue(item, flow: :link_existing_account, account_id: first.id)
      existing = BrexItem::Selection.from_token(token, flow: :link_existing_account, account_id: first.id)
      creation = BrexItem::Selection.from_token(BrexItem::Selection.issue(item, flow: :link_accounts), flow: :link_accounts)
      command = brex_command(item, actor)
      Provider::Brex.expects(:new).never
      assert_no_difference [ "Account.count", "AccountProvider.count", "BrexAccount.count", "Sync.count" ] do
        assert_raises(Fence::OwnershipChanged) { command.link_existing_account(account_id: second.id, brex_account_id: "checking-1", selection: existing) }
        assert_raises(Fence::OwnershipChanged) { command.link_accounts(account_ids: [ "checking-1" ], account_type: "Depository", selection: existing) }
        assert_raises(Fence::OwnershipChanged) { command.complete_account_setup(account_types: {}, account_subtypes: {}, selection: creation) }
      end
    end
  end

  test "retained policy blocks destructive unlink and direct scheduling cannot remove linked accounts" do
    with_brex_context do |item, actor|
      account = brex_financial(item, actor)
      source = item.brex_accounts.create!(account_id: "checking-1", name: "Checking", currency: "USD", account_kind: "cash")
      link = AccountProvider.create!(account: account, provider: source)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      before = [ account.reload.attributes, link.reload.attributes, policy.reload.attributes ]
      DestroyJob.expects(:perform_later).never
      assert_raises(Fence::OwnershipChanged) { brex_command(item, actor).disconnect }
      assert_raises(Fence::OwnershipChanged) { item.destroy_later }
      assert_equal before, [ account.reload.attributes, link.reload.attributes, policy.reload.attributes ]
      assert_not item.reload.scheduled_for_deletion?
    end
  end
end
