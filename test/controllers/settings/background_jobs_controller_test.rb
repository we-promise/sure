require "test_helper"

class Settings::BackgroundJobsControllerTest < ActionDispatch::IntegrationTest
  setup do
    stub_sidekiq
  end

  test "super admin can view the console" do
    sign_in users(:sure_support_staff)

    get settings_background_jobs_path

    assert_response :success
  end

  test "console renders in-flight operations with actions" do
    sign_in users(:sure_support_staff)

    stuck = imports(:transaction)
    stuck.update_columns(status: "importing", updated_at: 1.hour.ago)

    fresh_sync = Sync.create!(syncable: accounts(:depository), status: :syncing)

    get settings_background_jobs_path

    assert_response :success
    assert_match stuck.id, response.body
    assert_match fresh_sync.id, response.body
    assert_match I18n.t("settings.background_jobs.operation.actions.mark_failed"), response.body
  end

  test "family admin is redirected away" do
    sign_in users(:family_admin)

    get settings_background_jobs_path

    assert_redirected_to root_path
  end

  test "member is redirected away" do
    sign_in users(:family_member)

    get settings_background_jobs_path

    assert_redirected_to root_path
  end

  test "cancel marks a stuck import as failed and writes an audit entry" do
    sign_in users(:sure_support_staff)

    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 1.hour.ago)

    assert_difference "DebugLogEntry.count", 1 do
      post cancel_settings_background_jobs_path(record_type: "Import", id: import.id)
    end

    assert_redirected_to settings_background_jobs_path
    assert_equal "failed", import.reload.status

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "background_jobs", entry.category
    assert_equal users(:sure_support_staff).id, entry.metadata["actor_user_id"]
  end

  test "cancel releases a stuck PdfImport claim back to pending" do
    sign_in users(:sure_support_staff)

    pdf = imports(:pdf)
    pdf.update_columns(status: "importing", updated_at: 1.hour.ago)

    post cancel_settings_background_jobs_path(record_type: "Import", id: pdf.id)

    assert_equal "pending", pdf.reload.status
  end

  test "cancel marks a stuck sync as stale" do
    sign_in users(:sure_support_staff)

    sync = Sync.create!(syncable: accounts(:depository), status: :syncing)
    sync.update_columns(updated_at: 1.hour.ago)

    post cancel_settings_background_jobs_path(record_type: "Sync", id: sync.id)

    assert_equal "stale", sync.reload.status
  end

  test "cancel refuses a record inside the stuck window" do
    sign_in users(:sure_support_staff)

    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 1.minute.ago)

    post cancel_settings_background_jobs_path(record_type: "Import", id: import.id)

    assert_equal "importing", import.reload.status
    assert_equal I18n.t("settings.background_jobs.cancel.not_cancellable"), flash[:alert]
  end

  test "cancel refuses when the record's job is visibly running" do
    sign_in users(:sure_support_staff)

    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 1.hour.ago)

    stub_sidekiq(worker_payloads: [
      { "wrapped" => "ImportJob", "args" => [ { "arguments" => [ { "_aj_globalid" => import.to_global_id.to_s } ] } ] }
    ])

    post cancel_settings_background_jobs_path(record_type: "Import", id: import.id)

    assert_equal "importing", import.reload.status
  end

  test "cancel refuses unknown record types" do
    sign_in users(:sure_support_staff)

    post cancel_settings_background_jobs_path(record_type: "User", id: users(:family_admin).id)

    assert_response :not_found
  end

  test "cancel requires super admin" do
    sign_in users(:family_admin)

    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 1.hour.ago)

    post cancel_settings_background_jobs_path(record_type: "Import", id: import.id)

    assert_redirected_to root_path
    assert_equal "importing", import.reload.status
  end

  private
    def stub_sidekiq(worker_payloads: [])
      process_set = mock("ProcessSet")
      process_set.stubs(:size).returns(1)
      process_set.stubs(:sum).returns(worker_payloads.size)
      Sidekiq::ProcessSet.stubs(:new).returns(process_set)

      stats = mock("Stats")
      stats.stubs(:enqueued).returns(0)
      stats.stubs(:retry_size).returns(0)
      stats.stubs(:dead_size).returns(0)
      stats.stubs(:scheduled_size).returns(0)
      Sidekiq::Stats.stubs(:new).returns(stats)

      Sidekiq::Queue.stubs(:all).returns([])

      workers = mock("Workers")
      yields = worker_payloads.map { |payload| [ "process", "thread", { "payload" => payload.to_json } ] }
      if yields.any?
        workers.stubs(:each).multiple_yields(*yields)
      else
        workers.stubs(:each)
      end
      Sidekiq::Workers.stubs(:new).returns(workers)
    end
end
