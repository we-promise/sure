require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class AkahuItem::SyncRequestTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    Provider::Akahu.expects(:new).never
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "an unmigrated request queues its original legacy owner and leaves a visible run alone" do
    with_source do |item, actor|
      sync = nil
      assert_enqueued_with(job: SyncJob) { sync = request(item, actor).call }
      assert_equal [ "AkahuItem", item.id ], [ sync.syncable_type, sync.syncable_id ]
      assert_empty ProviderConnection.where(family_id: item.family_id)
      assert_no_difference "Sync.count" do
        assert_no_enqueued_jobs { assert_nil request(item, actor).call }
      end
    end
  end

  test "active and retired owners queue only their exact native connection" do
    %w[active retired].each do |state|
      with_source do |item, actor|
        control = native_owner(item, state: state)
        sync = nil
        assert_enqueued_with(job: SyncJob) { sync = request(item, actor).call }
        assert_equal [ "ProviderConnection", control.provider_connection_id ], [ sync.syncable_type, sync.syncable_id ]
        assert_empty item.syncs
        assert_equal state, control.reload.state
        assert_no_difference "Sync.count" do
          assert_no_enqueued_jobs { assert_nil request(item, actor).call }
        end
      end
    end
  end

  test "a shadow copy still queues the legacy owner while its native connection is disabled" do
    with_source do |item, actor|
      control = native_owner(item, state: "shadow")
      control.provider_connection.update!(status: "disabled")
      sync = request(item, actor).call
      assert_equal [ "AkahuItem", item.id ], [ sync.syncable_type, sync.syncable_id ]
      assert_empty control.provider_connection.syncs
    end
  end

  test "missing connection and missing or mismatched mapping refuse native dispatch" do
    %i[connection mapping wrong_item].each do |missing|
      with_source do |item, actor|
        control = native_owner(item, connection: missing != :connection, mapping: false)
        if missing == :wrong_item
          ProviderMigrationMapping.create!(family: item.family, provider_migration_control: control,
            role: "connection", legacy_type: "AkahuItem", legacy_id: SecureRandom.uuid,
            provider_connection: control.provider_connection)
        end
        assert_refused { request(item, actor).call }
      end
    end
  end

  test "foreign family and wrong provider control identities cannot redirect a request" do
    with_source do |item, actor|
      native_owner(item, family: create_family)
      assert_refused { request(item, actor).call }
    end
    with_source do |item, actor|
      native_owner(item, provider_key: "up")
      assert_refused { request(item, actor).call }
    end
  end

  test "transitional controls queue neither writer" do
    %w[quiescing rollback_pending].each do |state|
      with_source do |item, actor|
        native_owner(item, state: state)
        assert_refused { request(item, actor).call }
      end
    end
  end

  test "cached control and UI syncing flags do not override fresh routing and visible Sync rows" do
    with_source do |item, actor|
      control = native_owner(item, state: "shadow")
      ProviderMigrationControl.where(id: control.id).update_all(state: "active")
      item.syncs.load
      previous = Current.syncing_by_syncable
      Current.syncing_by_syncable = { [ "AkahuItem", item.id ] => true,
        [ "ProviderConnection", control.provider_connection_id ] => true }
      begin
        sync = request(item, actor).call
        assert_equal "shadow", control.state
        assert_equal control.provider_connection_id, sync.syncable_id
        assert_equal "ProviderConnection", sync.syncable_type
        Current.syncing_by_syncable = {}
        assert_no_difference "Sync.count" do
          assert_no_enqueued_jobs { assert_nil request(item, actor).call }
        end
      ensure
        Current.syncing_by_syncable = previous
      end
    end
  end

  test "a mode change between capture and admission refuses rather than falling back" do
    [ [ "shadow", "active" ], [ "active", "shadow" ] ].each do |before, after|
      with_source do |item, actor|
        control = native_owner(item, state: before)
        command = changing_request(item, actor) { control.update!(state: after) }
        assert_refused { command.call }
      end
    end
  end

  test "native unavailable status deletion and original item deletion flags refuse dispatch" do
    %i[requires_update disabled target_deleting item_deleting].each do |mode|
      with_source do |item, actor|
        control = native_owner(item)
        case mode
        when :requires_update, :disabled then control.provider_connection.update!(status: mode.to_s)
        when :target_deleting then control.provider_connection.update!(scheduled_for_deletion: true)
        when :item_deleting then item.update!(scheduled_for_deletion: true)
        end
        assert_refused { request(item, actor).call }
      end
    end
  end

  test "fresh active admin and family checks reject changed and missing actors" do
    [ { role: "member" }, { active: false }, :family, :missing ].each do |change|
      with_source do |item, actor|
        command = request(item, actor)
        case change
        when :family then actor.update_columns(family_id: create_family.id)
        when :missing then actor.delete
        else actor.update_columns(change)
        end
        assert_refused { command.call }
      end
    end
    with_source { |item, _actor| assert_refused { request(item, nil).call } }
  end

  test "an actor changed after preflight is rejected under its fresh row lock" do
    with_source do |item, actor|
      command = changing_request(item, actor) { actor.update_columns(role: "member") }
      assert_refused { command.call }
    end
  end

  test "the command pins item and family scalars even if the caller mutates its same object" do
    %i[reparented missing].each do |mode|
      with_source do |item, actor|
        command = request(item, actor)
        if mode == :reparented
          item.update!(family: create_family)
        else
          item.delete
        end
        assert_refused { command.call }
      end
    end
  end

  test "the fixed provider subclass refuses other model types and unsaved items" do
    with_source do |item, actor|
      assert_raises(Fence::InvalidSource) { request(actor, actor) }
      assert_raises(Fence::InvalidSource) { request(item.dup, actor) }
      assert_raises(Fence::InvalidSource) do
        Provider::AccountData::LegacySyncRequest.new(item: item, actor: actor)
      end
    end
  end

  test "competing native connection control and actor locks return Busy without dispatch" do
    %i[connection control actor].each do |locked|
      with_source do |item, actor|
        control = native_owner(item)
        record = { connection: control.provider_connection, control: control, actor: actor }.fetch(locked)
        with_locked_record(record) do
          assert_no_difference "Sync.count" do
            assert_no_enqueued_jobs { assert_raises(Fence::Busy) { request(item, actor).call } }
          end
        end
      end
    end
  end

  test "another session holding the item drain prevents both legacy and native requests" do
    [ false, true ].each do |native|
      with_source do |item, actor|
        native_owner(item) if native
        with_other_session(->(&work) { Fence.with_exclusive(item, &work) }) do
          assert_no_difference "Sync.count" do
            assert_no_enqueued_jobs { assert_raises(Fence::Busy) { request(item, actor).call } }
          end
        end
      end
    end
  end

  test "an older pending native Sync is reused only after a nonblocking lock" do
    with_source do |item, actor|
      control = native_owner(item)
      original = control.provider_connection.syncs.create!(created_at: 10.minutes.ago)
      assert_not original.visible?

      with_locked_record(original) do
        assert_no_difference "Sync.count" do
          assert_no_enqueued_jobs { assert_raises(Fence::Busy) { request(item, actor).call } }
        end
      end

      result = nil
      assert_no_difference "Sync.count" do
        assert_enqueued_with(job: SyncJob, args: [ original ]) { result = request(item, actor).call }
      end
      assert_equal original.id, result.id
      assert_predicate original.reload, :pending?
      assert_empty item.syncs
    end
  end

  test "Sync creation failure rolls back before dispatch and a fresh request can retry" do
    with_source do |item, actor|
      callback = lambda do |sync|
        raise IOError, "Simulated Sync creation failure" if sync.syncable_type == "AkahuItem" && sync.syncable_id == item.id
      end
      Sync.set_callback(:create, :after, callback)
      begin
        assert_no_difference "Sync.count" do
          assert_no_enqueued_jobs { assert_raises(IOError) { request(item, actor).call } }
        end
      ensure
        Sync.skip_callback(:create, :after, callback)
      end
      assert_enqueued_with(job: SyncJob) { request(item, actor).call }
    end
  end

  private
    def request(item, actor)
      AkahuItem::SyncRequest.new(item: item, actor: actor)
    end

    def assert_refused(&block)
      assert_no_difference "Sync.count" do
        assert_no_enqueued_jobs { assert_raises(Fence::OwnershipChanged, &block) }
      end
    end

    def changing_request(item, actor, &change)
      Class.new(AkahuItem::SyncRequest) do
        define_method(:routing) do |lock: false|
          super(lock: lock).tap do
            unless lock || @changed
              @changed = true
              change.call
            end
          end
        end
      end.new(item: item, actor: actor)
    end

    def with_source
      with_provider_encryption do
        @families, @users, @items, @connections, @controls = [], [], [], [], []
        family = create_family
        actor = family.users.create!(email: "akahu-sync-#{SecureRandom.uuid}@example.com", password: "akahu-sync-test-password", role: "admin")
        @users << actor
        item = family.akahu_items.create!(name: "Manual Akahu sync", app_token: "private-app-token", user_token: "private-user-token")
        @items << item
        yield item, actor
      ensure
        Sync.where(syncable_type: "ProviderConnection", syncable_id: @connections.map(&:id)).destroy_all
        Sync.where(syncable_type: "AkahuItem", syncable_id: @items.map(&:id)).destroy_all
        ProviderMigrationMapping.where(provider_migration_control_id: @controls.map(&:id)).delete_all
        ProviderMigrationControl.where(id: @controls.map(&:id)).delete_all
        @connections.each(&:destroy!)
        AkahuItem.where(id: @items.map(&:id)).delete_all
        User.where(id: @users.map(&:id)).delete_all
        @families.each(&:destroy!)
      end
    end

    def create_family
      Family.create!(name: "Akahu manual sync test").tap { |family| @families << family }
    end

    def native_owner(item, state: "active", family: item.family, provider_key: "akahu", connection: true, mapping: true)
      credentials = provider_key == "akahu" ? { "app_token" => "native-app-token", "user_token" => "native-user-token" } : { "access_token" => "native-token" }
      target = create_provider_connection(family: family, provider_key: provider_key, credentials: credentials) if connection
      @connections << target if target
      control = ProviderMigrationControl.create!(family: family, provider_key: provider_key, legacy_type: "AkahuItem",
        legacy_id: item.id, state: state, provider_connection: target)
      @controls << control
      if mapping && target
        ProviderMigrationMapping.create!(family: family, provider_migration_control: control, role: "connection",
          legacy_type: "AkahuItem", legacy_id: item.id, provider_connection: target)
      end
      control
    end

    def with_locked_record(record, &block)
      with_other_session(lambda do |&work|
        record.class.transaction do
          record.class.where(id: record.id).lock("FOR UPDATE").first!
          work.call
        end
      end, &block)
    end

    def with_other_session(admit)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          admit.call do
            ready << true
            release.pop
          end
        end
      rescue Exception => error
        ready << error
        raise
      end
      acquired = Timeout.timeout(5) { ready.pop }
      raise acquired if acquired.is_a?(Exception)
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
end
