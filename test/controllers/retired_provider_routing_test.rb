require "test_helper"
require_relative "../support/identity_bootstrap_test_helper"

class RetiredProviderRoutingTest < ActionDispatch::IntegrationTest
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @route_sessions = []
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    ApplicationController.any_instance.stubs(:family_needs_auto_sync?).returns(false)
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
    Provider::Up.expects(:new).never
    sign_in_for_routes(users(:family_admin))
  end

  teardown do
    Session.where(id: @route_sessions).delete_all
    Current.reset
    clear_enqueued_jobs
  end

  test "saved edit and setup URLs reach their exact native screens after actual retirement" do
    with_retired_connection do |context|
      connection = context.control.provider_connection
      archives = archive_bytes(context)

      get edit_up_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(connection)
      assert_equal I18n.t("provider_connections.legacy_route.moved"), flash[:notice]

      get setup_accounts_up_item_path(context.item.id)
      assert_redirected_to provider_connection_account_setup_path(connection)

      assert_equal archives, archive_bytes(context)
      refute UpItem.exists?(context.item.id)
      assert_equal context.link.id, context.external.reload.account_provider.id
    end
  end

  test "stale update destroy and setup submissions preserve native data and require a fresh shared form" do
    with_retired_connection do |context|
      connection = context.control.provider_connection
      original = connection.attributes
      financial = identity_financial_snapshot(context)
      archives = archive_bytes(context)

      patch up_item_path(context.item.id), params: { up_item: { name: "Obsolete edit", access_token: "private-stale-secret" } }
      assert_redirected_to edit_provider_connection_path(connection)
      delete up_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(connection)
      post complete_account_setup_up_item_path(context.item.id), params: { account_types: { context.source.id => "Loan" } }
      assert_redirected_to provider_connection_account_setup_path(connection)

      assert_equal original, connection.reload.attributes
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal archives, archive_bytes(context)
      assert AccountProvider.exists?(context.link.id)
      refute_includes flash.to_hash.to_s, "private-stale-secret"
    end
  end

  test "old JSON mutation receives a safe conflict with the shared destination" do
    with_retired_connection do |context|
      patch up_item_path(context.item.id, format: :json), params: { up_item: { access_token: "private-stale-secret" } }

      assert_response :conflict
      assert_equal({ "error" => "connection_moved", "location" => edit_provider_connection_path(context.control.provider_connection_id) }, response.parsed_body)
      refute_includes response.body, "private-stale-secret"
      assert AccountProvider.exists?(context.link.id)
    end
  end

  test "saved manual sync queues only the shared owner and retries the same pending Sync" do
    with_retired_connection do |context|
      connection = context.control.provider_connection
      original_legacy = Sync.where(syncable_type: "UpItem", syncable_id: context.item.id).order(:id).map(&:attributes)
      clear_enqueued_jobs

      assert_difference -> { connection.syncs.count }, 1 do
        post sync_up_item_path(context.item.id, format: :json)
        assert_response :ok
      end
      run = connection.syncs.incomplete.sole
      assert_enqueued_with(job: SyncJob, args: [ run ])
      assert_no_difference -> { connection.syncs.count } do
        post sync_up_item_path(context.item.id, format: :json)
        assert_response :ok
      end

      assert_equal run.id, connection.syncs.incomplete.sole.id
      assert_equal original_legacy, Sync.where(syncable_type: "UpItem", syncable_id: context.item.id).order(:id).map(&:attributes)
    end
  end

  test "missing retirement witness refuses routing and manual work" do
    with_retired_connection(retire: false) do |context|
      context.control.update!(state: "retired")
      UpAccount.where(id: context.source.id).delete_all
      UpItem.where(id: context.item.id).delete_all
      clear_enqueued_jobs

      get edit_up_item_path(context.item.id)
      assert_redirected_to settings_providers_path
      assert_no_difference "Sync.count" do
        post sync_up_item_path(context.item.id, format: :json)
        assert_response :conflict
      end
      assert_no_enqueued_jobs only: SyncJob
      assert AccountProvider.exists?(context.link.id)
    end
  end

  test "a member cannot use a retired admin route and another family cannot resolve its original UUID" do
    with_retired_connection do |context|
      original = context.control.provider_connection.syncs.count
      sign_in_for_routes(users(:family_member))
      post sync_up_item_path(context.item.id, format: :json)
      assert_response :forbidden
      sign_in_for_routes(users(:empty))
      get edit_up_item_path(context.item.id)
      assert_response :not_found

      assert_equal original, context.control.provider_connection.syncs.count
    end
  end

  test "a connection requiring attention stays editable but cannot queue a manual sync" do
    with_retired_connection do |context|
      connection = context.control.provider_connection
      connection.update!(status: "requires_update")
      clear_enqueued_jobs

      get edit_up_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(connection)
      assert_no_difference "Sync.count" do
        post sync_up_item_path(context.item.id, format: :json)
        assert_response :conflict
      end
      assert_no_enqueued_jobs only: SyncJob
    end
  end

  test "diagnostic failures cannot expose exception text or replace a routing refusal" do
    with_retired_connection do |context|
      context.control.provider_connection.update!(status: "requires_update")
      DebugLogEntry.stubs(:capture).raises(StandardError, "private-diagnostic-context")

      post sync_up_item_path(context.item.id, format: :json)

      assert_response :conflict
      assert_equal({ "error" => "conflict" }, response.parsed_body)
      refute_includes response.body, "private-diagnostic-context"
    end
  end

  test "each reviewed controller supplies its fixed provider key before attempting a missing item lookup" do
    { "up" => :edit_up_item_path, "mercury" => :edit_mercury_item_path, "brex" => :edit_brex_item_path,
      "akahu" => :edit_akahu_item_path }.each do |key, path|
      id = SecureRandom.uuid
      connection = ProviderConnection.new(id: SecureRandom.uuid)
      route = mock("retired #{key} route")
      ProviderConnection::LegacyRoute.expects(:new).with do |arguments|
        arguments[:provider_key] == key && arguments[:legacy_id] == id &&
          arguments[:family].id == families(:dylan_family).id && arguments[:actor].id == users(:family_admin).id
      end.returns(route)
      options = { sync: false }
      options[:include_live] = true if key == "akahu"
      route.expects(:call).with(**options).returns(ProviderConnection::LegacyRoute::Result.new(connection: connection, sync: nil))

      get public_send(path, id)
      assert_redirected_to edit_provider_connection_path(connection)
    end
  end

  private
    def sign_in_for_routes(user)
      sign_in(user)
      @route_sessions << Current.session.id
    end

    def with_retired_connection(retire: true)
      family = families(:dylan_family)
      activity = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
      with_identity_source do |context|
        prepared = nil
        150.times do
          prepared = Provider::AccountData::MigrationPreparation.new(provider_key: "up", legacy_item_id: context.item.id,
            family: context.family, page_size: 1).run
          break if prepared.awaiting_acceptance?
        end
        assert prepared.awaiting_acceptance?
        cutover = Provider::AccountData::MigrationCutover.new(provider_key: "up", legacy_item_id: context.item.id,
          family: context.family, page_size: 1).call
        # Preserve the real receipt; this test never performs a provider request.
        Sync.find(cutover.sync_id).update!(status: "failed", completed_at: Time.current)
        if retire
          Provider::AccountData::MigrationRetirement.new(provider_key: "up", legacy_item_id: context.item.id, family: context.family).call
        end
        context.control.reload
        clear_enqueued_jobs
        yield context
      ensure
        Sync.where(syncable_type: "ProviderConnection", syncable_id: context.control.provider_connection_id).delete_all
      end
    ensure
      Family.where(id: family.id).update_all(activity) if family && activity
    end

    def archive_bytes(context)
      context.control.provider_connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text"))
    end
end
