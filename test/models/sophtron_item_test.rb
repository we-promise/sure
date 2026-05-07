require "test_helper"

class SophtronItemTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
  end

  test "ensure_customer reuses persisted customer id" do
    @item.update!(customer_id: "cust-existing")
    provider = mock
    provider.expects(:list_customers).never

    assert_equal "cust-existing", @item.ensure_customer!(provider: provider)
  end

  test "ensure_customer reuses matching listed customer" do
    provider = mock
    provider.expects(:list_customers).returns([
      { CustomerID: "cust-1", CustomerName: @item.generated_customer_name }
    ])
    provider.expects(:create_customer).never

    assert_equal "cust-1", @item.ensure_customer!(provider: provider)
    assert_equal "cust-1", @item.customer_id
    assert_equal @item.generated_customer_name, @item.customer_name
  end

  test "ensure_customer creates customer when no matching customer exists" do
    provider = mock
    provider.expects(:list_customers).returns([])
    provider.expects(:create_customer)
      .with(unique_id: @item.generated_customer_unique_id, name: @item.generated_customer_name, source: "Sure")
      .returns({ CustomerID: "cust-new", CustomerName: @item.generated_customer_name })

    assert_equal "cust-new", @item.ensure_customer!(provider: provider)
    assert_equal "cust-new", @item.customer_id
  end

  test "connected_to_institution ignores failed connection attempts" do
    @item.update!(user_institution_id: "ui-1", status: :requires_update)

    assert_not @item.connected_to_institution?
  end

  test "connected_to_institution ignores jobs that are still running" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1", status: :good)

    assert_not @item.connected_to_institution?
  end

  test "connected_to_institution ignores stale timeout job snapshots" do
    @item.update!(
      user_institution_id: "ui-1",
      status: :good,
      job_status: "Timeout",
      raw_job_payload: {
        SuccessFlag: false,
        LastStatus: "Timeout"
      }
    )

    assert_not @item.connected_to_institution?
  end

  test "start_initial_load_later starts a sync when no active sync exists" do
    assert_no_enqueued_jobs only: SophtronInitialLoadJob do
      assert_difference "@item.syncs.count", 1 do
        assert_enqueued_with job: SyncJob do
          @item.start_initial_load_later
        end
      end
    end
  end

  test "start_initial_load_later seeds sync window for transaction import" do
    @item.update!(sync_start_date: Date.new(2026, 1, 1))

    @item.start_initial_load_later

    assert_equal Date.new(2026, 1, 1), @item.syncs.ordered.first.window_start_date
  end

  test "start_initial_load_later queues a follow-up when current sync is already running" do
    sync = @item.syncs.create!
    sync.start!

    assert_no_difference "@item.syncs.count" do
      assert_enqueued_with job: SophtronInitialLoadJob do
        @item.start_initial_load_later
      end
    end
  end
end
