require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::LegacyWriterFenceTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "a legacy item without a control may write outside a database transaction" do
    with_item do |item|
      assert_nil ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)
      result = Fence.with_item(item) do |current|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_not_same item, current
        current.update!(name: "Admitted import")
        :written
      end
      assert_equal :written, result
      assert_equal "Admitted import", item.reload.name
      assert_nil ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)
    end
  end

  test "every legacy owned control state permits dispatch while every other state rejects it" do
    with_item do |item|
      control = control_for(item)
      ProviderMigrationControl.states.each_key do |state|
        control.update!(state: state)
        if ProviderMigrationControl::LEGACY_STATES.include?(state)
          assert_equal :admitted, Fence.with_item(item) { :admitted }
        else
          assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk "Native or quiescing source must not write" } }
        end
      end
    end
  end

  test "an in-flight writer prevents an exclusive drain before a control row exists" do
    with_item do |item|
      Fence.with_item(item) do
        assert_equal :busy, in_another_session { try_drain(item) }
        assert_nil ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)
      end
      Fence.with_exclusive(item) { control_for(item, state: "quiescing") }
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk "Ownership must be read after locking" } }
    end
  end

  test "exclusive draining prevents new readers without requiring a control row" do
    with_item do |item|
      Fence.with_exclusive(item) do
        result = in_another_session do
          Fence.with_item(item) { :unexpected_write }
        rescue Fence::Busy
          :busy
        end
        assert_equal :busy, result
      end
      assert_equal :admitted, Fence.with_item(item) { :admitted }
    end
  end

  test "ownership checks bypass a request query cache populated before another session quiesces" do
    with_item do |item|
      control = control_for(item)
      ApplicationRecord.cache do
        assert ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id).legacy_owned?
        in_another_session do
          Fence.with_exclusive(item) { ProviderMigrationControl.where(id: control.id).update_all(state: "quiescing") }
        end
        assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk "Cached ownership cannot authorize a write" } }
      end
    end
  end

  test "same-item reentry keeps the outer permit across an ordinary write transaction" do
    with_item do |item|
      Fence.with_item(item) do
        UpItem.transaction do
          Fence.with_item(UpItem.find(item.id), operation: :publish) { |current| current.update!(name: "Nested write") }
        end
        assert_equal :busy, in_another_session { try_drain(item) }
      end
      assert_equal "Nested write", item.reload.name
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "nested calls retain only the current permit's freshly admitted observation state" do
    with_provider_encryption do
      item = SimplefinItem.create!(family: families(:dylan_family), name: "Fenced discovery", access_url: "https://example.com/fenced")
      item.upstream_account_ids = [ "stale-outside-proof" ]
      admitted = nil
      Fence.with_item(item, operation: :sync) do |current|
        admitted = current
        assert_nil current.upstream_account_ids
        current.upstream_account_ids = [ "current-discovery" ]
        processing_observations = []
        current.define_singleton_method(:repair_stale_linkages) do |_accounts|
          processing_observations << upstream_account_ids
        end
        assert_equal [], current.process_accounts
        assert_equal [ [ "current-discovery" ] ], processing_observations
        Fence.with_item(item, operation: :publish) do |nested|
          assert_same current, nested
          assert_equal [ "current-discovery" ], nested.upstream_account_ids
        end
      end
      Fence.with_item(admitted, operation: :publish) do |later|
        assert_not_same admitted, later
        assert_nil later.upstream_account_ids
      end
    ensure
      item&.destroy! if item&.persisted?
    end
  end

  test "a permit cannot upgrade to a drain or silently add another item" do
    with_item do |item|
      with_item do |other|
        Fence.with_item(item) do
          assert_raises(ArgumentError) { Fence.with_exclusive(item) { flunk "Cannot cut over inside a legacy write" } }
          assert_raises(ArgumentError) { Fence.with_item(other) { flunk "Cross-item locking needs a declared order" } }
        end
        Fence.with_exclusive(item) do
          assert_raises(ArgumentError) { Fence.with_item(item) { flunk "Migration cannot invoke legacy publication" } }
        end
      end
    end
  end

  test "unrelated item identities do not block each other's drain" do
    with_item do |item|
      with_item do |other|
        Fence.with_item(item) { assert_equal :drained, in_another_session { try_drain(other) } }
      end
    end
  end

  test "exceptions and rejected ownership release the physical session lock" do
    with_item do |item|
      assert_raises(IOError) { Fence.with_item(item) { raise IOError, "Simulated caller failure" } }
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_equal :drained, in_another_session { try_drain(item) }
      control_for(item, state: "active")
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk } }
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "entry inside a database transaction is rejected before any provider work" do
    with_item do |item|
      UpItem.transaction do
        assert_raises(ArgumentError) { Fence.with_item(item) { flunk "Must not enclose HTTP in a database transaction" } }
        assert_raises(ArgumentError) { Fence.with_exclusive(item) { flunk "Drain must precede row locks" } }
      end
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "source classes and family identity cannot be supplied as an untrusted shortcut" do
    with_item do |item|
      assert_not Fence.legacy_item?(families(:dylan_family))
      assert_raises(Fence::InvalidSource) { Fence.with_item(families(:dylan_family)) { flunk } }
      assert_raises(Fence::InvalidSource) { Fence.with_item(UpItem.new(id: SecureRandom.uuid, family: item.family)) { flunk } }
      item.family_id = families(:empty).id
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk "Stale family must not be adopted" } }
    end
  end

  test "an account resolves its exact parent item and shares the same exclusion key" do
    with_item do |item|
      account = item.up_accounts.create!(account_id: "up-source-account", name: "Checking", currency: "AUD")
      Fence.with_account(account) do |current|
        assert_equal account.id, current.id
        assert_equal :busy, in_another_session { try_drain(item) }
      end
      control_for(item, state: "quiescing")
      assert_raises(Fence::OwnershipChanged) { Fence.with_account(account) { flunk } }
    end
  end

  test "common legacy dispatch rebuilds the syncer from freshly reloaded source credentials" do
    with_item do |item|
      stale = UpItem.find(item.id)
      item.update!(access_token: "replacement-token")
      sync = item.syncs.create!
      worker = mock("legacy syncer")
      worker.expects(:perform_sync).with(sync).returns(:processed)
      UpItem::Syncer.expects(:new).with do |current|
        assert_equal item.id, current.id
        assert_equal "replacement-token", current.access_token
        assert_equal 0, ApplicationRecord.connection.open_transactions
        true
      end.returns(worker)
      assert_equal :processed, stale.perform_sync(sync)
    end
  end

  test "common dispatch never enters a legacy syncer after ownership has changed" do
    with_item do |item|
      sync = item.syncs.create!
      control_for(item, state: "active")
      UpItem::Syncer.expects(:new).never
      assert_raises(Fence::OwnershipChanged) { item.perform_sync(sync) }
    end
  end

  test "direct Up import passes its receiver reloaded after entry to the importer" do
    with_item do |item|
      stale = UpItem.find(item.id)
      item.update!(access_token: "new-direct-import-token")
      importer = mock("current Up importer")
      result = { imported: 3 }
      UpItem::Importer.expects(:new).with do |current|
        current.id == item.id && !current.equal?(stale) &&
          current.access_token == "new-direct-import-token" &&
          ApplicationRecord.connection.open_transactions.zero?
      end.returns(importer)
      importer.expects(:import).returns(result)

      assert_same result, stale.import_latest_up_data
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "direct Up processing rebuilds its account query instead of using cached snapshots" do
    with_item do |item|
      source = item.up_accounts.create!(account_id: "direct-up-account", name: "Checking", currency: "AUD", current_balance: 10)
      AccountProvider.create!(account: accounts(:depository), provider: source)
      stale = UpItem.find(item.id)
      stale.up_accounts.load
      source.update!(current_balance: 25)
      processor = mock("fresh account processor")
      UpAccount::Processor.expects(:new).with do |current|
        current.id == source.id && current.current_balance == 25 &&
          current.up_item_id == item.id && ApplicationRecord.connection.open_transactions.zero?
      end.returns(processor)
      processor.expects(:process).returns(:processed)

      assert_equal [ { up_account_id: source.id, success: true, result: :processed } ], stale.process_accounts
    end
  end

  test "direct Up guards deny before client construction and original rescue diagnostics" do
    with_item do |item|
      control_for(item, state: "quiescing")
      Provider::Up.expects(:new).never
      UpItem::Importer.expects(:new).never
      UpAccount::Processor.expects(:new).never
      DebugLogEntry.expects(:capture).never

      assert_raises(Fence::OwnershipChanged) { item.import_latest_up_data }
      assert_raises(Fence::OwnershipChanged) { item.process_accounts }
    end
  end

  test "direct Up methods nest within dispatch without releasing its permit" do
    with_item do |item|
      Fence.with_item(item, operation: :sync) do |current|
        assert_equal [], current.process_accounts
        assert_equal :busy, in_another_session { try_drain(item) }
      end
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "a denied on-chain sync cannot fall through to financial post-sync repair" do
    with_provider_encryption do
      item = OnchainWalletItem.create!(family: families(:dylan_family), name: "Fenced wallet")
      ProviderMigrationControl.create!(family: item.family, provider_key: "onchain_wallet",
        legacy_type: "OnchainWalletItem", legacy_id: item.id, state: "active")
      sync = item.syncs.create!
      OnchainWalletItem::Syncer.expects(:new).never
      OnchainWalletItem.any_instance.expects(:perform_post_sync).never
      OnchainWalletItem.any_instance.expects(:broadcast_sync_complete).never
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:family] == item.family && attributes[:provider_key] == "onchain_wallet" &&
          attributes.dig(:metadata, :sync_id) == sync.id &&
          attributes.dig(:metadata, :error_class) == Fence::OwnershipChanged.name
      end

      sync.perform

      assert sync.reload.stale?
      assert_equal "Legacy provider execution was fenced", sync.error
    ensure
      if item&.persisted?
        ProviderMigrationControl.where(legacy_type: "OnchainWalletItem", legacy_id: item.id).destroy_all
        item.destroy!
      end
    end
  end

  test "a busy legacy drain terminalizes dispatch without running post-sync work" do
    with_item do |item|
      sync = item.syncs.create!
      Fence.expects(:with_item).with(item, operation: :sync).raises(Fence::Busy)
      UpItem::Syncer.expects(:new).never
      UpItem.any_instance.expects(:perform_post_sync).never
      UpItem.any_instance.expects(:broadcast_sync_complete).never
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes.dig(:metadata, :error_class) == Fence::Busy.name
      end

      sync.perform

      assert sync.reload.stale?
      assert_equal "Legacy provider execution was fenced", sync.error
    end
  end

  test "common dispatch leaves family and native connection work outside the legacy fence" do
    with_item do |item|
      family = item.family
      worker = mock("family syncer")
      sync = family.syncs.build
      family.stubs(:syncer).returns(worker)
      worker.expects(:perform_sync).with(sync).returns(:family_work)
      assert_equal :family_work, family.perform_sync(sync)
      assert_not Fence.legacy_item?(ProviderConnection.new(family: family, provider_key: "up"))
    end
  end

  private
    def with_item
      with_provider_encryption do
        item = UpItem.create!(family: families(:dylan_family), name: "Fenced Up connection", access_token: "private-up-token")
        begin
          yield item
        ensure
          ProviderMigrationControl.where(legacy_type: "UpItem", legacy_id: item.id).destroy_all
          item.reload.destroy!
        end
      end
    end

    def control_for(item, state: "legacy")
      ProviderMigrationControl.create!(family_id: item.family_id, provider_key: "up", legacy_type: "UpItem", legacy_id: item.id, state: state)
    end

    def try_drain(item)
      Fence.with_exclusive(item) { :drained }
    rescue Fence::Busy
      :busy
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new(&block)
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
