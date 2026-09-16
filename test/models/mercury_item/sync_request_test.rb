require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class MercuryItem::SyncRequestTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    Provider::Mercury.expects(:new).never
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "an unmigrated request schedules only its admitted legacy item" do
    with_source do |item, actor|
      sync = nil
      assert_enqueued_with(job: SyncJob) { sync = request(item, actor).call }
      assert_equal [ "MercuryItem", item.id ], [ sync.syncable_type, sync.syncable_id ]
      assert_empty ProviderConnection.all.where(family_id: item.family_id)
      assert_no_difference "Sync.count" do
        assert_no_enqueued_jobs { assert_nil request(item, actor).call }
      end
    end
  end

  test "active and retired owners schedule their exact mapped native connection" do
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

  test "legacy owned copied connections continue using the legacy permit" do
    with_source do |item, actor|
      control = native_owner(item, state: "shadow")
      sync = request(item, actor).call
      assert_equal item, sync.syncable
      assert_empty control.provider_connection.syncs
    end
  end

  test "native owner without a connection or exact mapping is refused" do
    [ :connection, :mapping ].each do |missing|
      with_source do |item, actor|
        native_owner(item, connection: missing != :connection, mapping: missing != :mapping)
        assert_refused { request(item, actor).call }
      end
    end
  end

  test "foreign family and wrong provider ownership cannot choose a native target" do
    with_source do |item, actor|
      foreign = create_family
      native_owner(item, family: foreign)
      assert_refused { request(item, actor).call }
    end
    with_source do |item, actor|
      native_owner(item, provider_key: "monobank")
      assert_refused { request(item, actor).call }
    end
  end

  test "a connection mapping to another legacy item is refused" do
    with_source do |item, actor|
      control = native_owner(item, mapping: false)
      ProviderMigrationMapping.create!(family: item.family, provider_migration_control: control,
        role: "connection", legacy_type: "MercuryItem", legacy_id: SecureRandom.uuid,
        provider_connection: control.provider_connection)
      assert_refused { request(item, actor).call }
    end
  end

  test "quiescing and rollback pending controls schedule neither writer" do
    %w[quiescing rollback_pending].each do |state|
      with_source do |item, actor|
        native_owner(item, state: state)
        assert_refused { request(item, actor).call }
      end
    end
  end

  test "cached control state is not authority at request admission" do
    with_source do |item, actor|
      cached = native_owner(item, state: "shadow")
      ProviderMigrationControl.where(id: cached.id).update_all(state: "active")
      assert_equal "shadow", cached.state
      sync = request(item, actor).call
      assert_equal cached.provider_connection_id, sync.syncable_id
      assert_equal "ProviderConnection", sync.syncable_type
      assert_empty item.syncs
    end
  end

  test "a mode change after routing capture rejects instead of falling back" do
    [ [ "shadow", "active" ], [ "active", "shadow" ] ].each do |before, after|
      with_source do |item, actor|
        control = native_owner(item, state: before)
        changing = changing_request(item, actor) { control.update!(state: after) }
        assert_refused { changing.call }
      end
    end
  end

  test "native disabled or deleting targets and a deleting original item are refused" do
    [ :disabled, :target_deleting, :item_deleting ].each do |mode|
      with_source do |item, actor|
        control = native_owner(item)
        case mode
        when :disabled then control.provider_connection.update!(status: "disabled")
        when :target_deleting then control.provider_connection.update!(scheduled_for_deletion: true)
        when :item_deleting then item.update!(scheduled_for_deletion: true)
        end
        assert_refused { request(item, actor).call }
      end
    end
  end

  test "fresh user role active status and family are checked instead of a cached actor" do
    [ { role: "member" }, { active: false }, :family ].each do |change|
      with_source do |item, actor|
        native_owner(item)
        command = request(item, actor)
        attributes = change == :family ? { family_id: create_family.id } : change
        User.where(id: actor.id).update_all(attributes)
        assert_refused { command.call }
      end
    end
  end

  test "a reparented or missing item does not retarget a previously constructed command" do
    [ :reparented, :missing ].each do |mode|
      with_source do |item, actor|
        command = request(item, actor)
        if mode == :reparented
          MercuryItem.where(id: item.id).update_all(family_id: create_family.id)
        else
          MercuryItem.where(id: item.id).delete_all
        end
        assert_refused { command.call }
      end
    end
  end

  test "a competing connection lock returns Busy before either writer is queued" do
    with_source do |item, actor|
      control = native_owner(item)
      with_locked_connection(control.provider_connection_id) do
        assert_no_difference "Sync.count" do
          assert_no_enqueued_jobs { assert_raises(Fence::Busy) { request(item, actor).call } }
        end
      end
    end
  end

  private
    def request(item, actor)
      MercuryItem::SyncRequest.new(item: item, actor: actor)
    end

    def assert_refused(&block)
      assert_no_difference "Sync.count" do
        assert_no_enqueued_jobs { assert_raises(Fence::OwnershipChanged, &block) }
      end
    end

    def changing_request(item, actor, &change)
      Class.new(MercuryItem::SyncRequest) do
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
        actor = family.users.create!(email: "mercury-sync-#{SecureRandom.uuid}@example.com", password: "mercury-sync-test-password", role: "admin")
        @users << actor
        item = family.mercury_items.create!(name: "Manual Mercury sync", token: "private-mercury-token")
        @items << item
        yield item, actor
      ensure
        Sync.where(syncable_type: "ProviderConnection", syncable_id: @connections.map(&:id)).destroy_all
        Sync.where(syncable_type: "MercuryItem", syncable_id: @items.map(&:id)).destroy_all
        ProviderMigrationMapping.where(provider_migration_control_id: @controls.map(&:id)).delete_all
        ProviderMigrationControl.where(id: @controls.map(&:id)).delete_all
        @connections.each(&:destroy!)
        MercuryItem.where(id: @items.map(&:id)).delete_all
        User.where(id: @users.map(&:id)).delete_all
        @families.each(&:destroy!)
      end
    end

    def create_family
      Family.create!(name: "Mercury manual sync test").tap { |family| @families << family }
    end

    def native_owner(item, state: "active", family: item.family, provider_key: "mercury", connection: true, mapping: true)
      target = create_provider_connection(family: family, provider_key: provider_key) if connection
      @connections << target if target
      control = ProviderMigrationControl.create!(family: family, provider_key: provider_key, legacy_type: "MercuryItem",
        legacy_id: item.id, state: state, provider_connection: target)
      @controls << control
      if mapping && target
        ProviderMigrationMapping.create!(family: family, provider_migration_control: control, role: "connection",
          legacy_type: "MercuryItem", legacy_id: item.id, provider_connection: target)
      end
      control
    end

    def with_locked_connection(id)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ProviderConnection.transaction do
            ProviderConnection.where(id: id).lock(true).first!
            ready << :locked
            release.pop
          end
        end
      rescue Exception => error
        ready << error
        raise
      end
      begin
        observed = Timeout.timeout(5) { ready.pop }
        raise observed if observed.is_a?(Exception)
        yield
      ensure
        release << true
        Timeout.timeout(5) { worker.value }
      end
    end
end
