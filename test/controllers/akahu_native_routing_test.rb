require "test_helper"
require_relative "../support/akahu_migration_test_helper"

class AkahuNativeRoutingTest < ActionDispatch::IntegrationTest
  include AkahuMigrationTestHelper
  self.use_transactional_tests = false

  setup do
    ensure_tailwind_build
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    ApplicationController.any_instance.stubs(:family_needs_auto_sync?).returns(false)
    Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
    Provider::Akahu.expects(:new).never
  end

  teardown do
    Current.reset
    clear_enqueued_jobs
  end

  test "live native edit and setup URLs reach shared screens without changing retained data" do
    with_routing_source do |context|
      original = retained_snapshot(context)

      get edit_akahu_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(context.connection)
      get setup_accounts_akahu_item_path(context.item.id)
      assert_redirected_to provider_connection_account_setup_path(context.connection)

      assert_equal original, retained_snapshot(context)
      assert AkahuItem.exists?(context.item.id)
      assert_equal context.link.id, context.external.reload.account_provider.id
    end
  end

  test "live native stale mutations redirect without replaying their legacy parameters" do
    with_routing_source do |context|
      original = retained_snapshot(context)

      patch akahu_item_path(context.item.id), params: { akahu_item: { name: "Obsolete name", user_token: "private-stale-token" } }
      assert_redirected_to edit_provider_connection_path(context.connection)
      delete akahu_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(context.connection)
      post complete_account_setup_akahu_item_path(context.item.id), params: { account_types: { context.source.id => "Loan" } }
      assert_redirected_to provider_connection_account_setup_path(context.connection)

      assert_equal original, retained_snapshot(context)
      refute context.item.reload.scheduled_for_deletion?
      refute_includes flash.to_hash.to_s, "private-stale-token"
    end
  end

  test "actual retirement preserves saved management routes and returns a destination for stale JSON" do
    with_routing_source(retire: true) do |context|
      original = retained_snapshot(context)

      get edit_akahu_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(context.connection)
      get setup_accounts_akahu_item_path(context.item.id)
      assert_redirected_to provider_connection_account_setup_path(context.connection)
      patch akahu_item_path(context.item.id, format: :json), params: { akahu_item: { user_token: "private-stale-token" } }
      assert_response :conflict
      assert_equal({ "error" => "connection_moved", "location" => edit_provider_connection_path(context.connection) }, response.parsed_body)

      assert_equal original, retained_snapshot(context)
      refute AkahuItem.exists?(context.item.id)
      refute_includes response.body, "private-stale-token"
    end
  end

  test "live and retired manual syncs retain one native pending run and original legacy history" do
    [ false, true ].each do |retired|
      with_routing_source(retire: retired) do |context|
        history = Sync.where(syncable_type: "AkahuItem", syncable_id: context.item.id).order(:id).map(&:attributes)
        clear_enqueued_jobs

        assert_difference -> { context.connection.syncs.count }, 1 do
          post sync_akahu_item_path(context.item.id, format: :json)
          assert_response :ok
        end
        run = context.connection.syncs.incomplete.sole
        assert_enqueued_with(job: SyncJob, args: [ run ])
        assert_no_difference -> { context.connection.syncs.count } do
          post sync_akahu_item_path(context.item.id, format: :json)
          assert_response :ok
        end

        assert_equal run.id, context.connection.syncs.incomplete.sole.id
        assert_equal history, Sync.where(syncable_type: "AkahuItem", syncable_id: context.item.id).order(:id).map(&:attributes)
      end
    end
  end

  test "native readiness remains required for live management and retired sync" do
    [ false, true ].each do |retired|
      with_routing_source(retire: retired) do |context|
        original = retained_snapshot(context)
        Provider::AccountData::Akahu.stubs(:native_ready?).returns(false)

        get edit_akahu_item_path(context.item.id)
        assert_redirected_to settings_providers_path
        if retired
          assert_no_difference "Sync.count" do
            post sync_akahu_item_path(context.item.id, format: :json)
            assert_response :conflict
          end
        end
        assert_equal original, retained_snapshot(context)
        assert_no_enqueued_jobs only: SyncJob
      ensure
        Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
      end
    end
  end

  test "a connection requiring attention remains editable but cannot queue retired manual work" do
    with_routing_source(retire: true) do |context|
      context.connection.update!(status: "requires_update")

      get edit_akahu_item_path(context.item.id)
      assert_redirected_to edit_provider_connection_path(context.connection)
      assert_no_difference "Sync.count" do
        post sync_akahu_item_path(context.item.id, format: :json)
        assert_response :conflict
      end
      assert_no_enqueued_jobs only: SyncJob
    end
  end

  test "saved routes retain administrator and family boundaries" do
    with_routing_source(retire: true) do |context|
      member = context.family.users.create!(email: "akahu-routing-member-#{SecureRandom.uuid}@example.com",
        password: user_password_test, role: "member", onboarded_at: 3.days.ago)
      sign_in member
      assert_no_difference "Sync.count" do
        post sync_akahu_item_path(context.item.id, format: :json)
        assert_response :forbidden
      end

      sign_in users(:empty)
      foreign_session = Current.session
      get edit_akahu_item_path(context.item.id)
      assert_response :not_found
    ensure
      foreign_session&.destroy!
    end
  end

  test "live management opt in cannot bypass the provider sync admission command" do
    with_routing_source do |context|
      route = ProviderConnection::LegacyRoute.new(provider_key: "akahu", legacy_id: context.item.id,
        family: context.family, actor: context.actor)
      assert_no_difference "Sync.count" do
        assert_raises(ArgumentError) { route.call(sync: true, include_live: true) }
      end
      assert_no_enqueued_jobs only: SyncJob
    end
  end

  private
    def with_routing_source(retire: false)
      with_akahu_migration_source do |context|
        if retire
          Provider::AccountData::MigrationRetirement.new(provider_key: "akahu", legacy_item_id: context.item.id,
            family: context.family).call
          context.control.reload
        end
        actor = context.family.users.create!(email: "akahu-routing-#{SecureRandom.uuid}@example.com",
          password: user_password_test, role: "admin", onboarded_at: 3.days.ago)
        sign_in actor
        clear_enqueued_jobs
        yield context
      end
    end

    def retained_snapshot(context)
      { connection: context.connection.reload.attributes, financial: identity_financial_snapshot(context),
        link: context.link.reload.attributes,
        archives: context.connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text")) }
    end
end
