require "test_helper"

class BackgroundJobConsoleTest < ActiveSupport::TestCase
  test "fails closed when Sidekiq/Redis is unreachable" do
    Sidekiq::ProcessSet.stubs(:new).raises(StandardError.new("no redis"))

    console = BackgroundJobConsole.new
    sync = Sync.create!(syncable: accounts(:depository), status: :syncing)
    sync.update_columns(updated_at: 1.hour.ago)

    assert console.redis_error?
    assert_nil console.stats
    assert_not console.cancellable?(sync)
  end

  test "detects running records via GlobalIDs in worker payloads" do
    sync = Sync.create!(syncable: accounts(:depository), status: :syncing)
    sync.update_columns(updated_at: 1.hour.ago)

    stub_sidekiq(worker_payloads: [
      { "wrapped" => "SyncJob", "args" => [ { "arguments" => [ { "_aj_globalid" => sync.to_global_id.to_s } ] } ] }
    ])

    console = BackgroundJobConsole.new

    assert console.running?(sync)
    assert_not console.cancellable?(sync)
  end

  test "cancellable only when idle past the stuck window with no live job" do
    stub_sidekiq

    console = BackgroundJobConsole.new

    fresh = Sync.create!(syncable: accounts(:depository), status: :syncing)
    stuck = Sync.create!(syncable: accounts(:connected), status: :syncing)
    stuck.update_columns(updated_at: 1.hour.ago)

    assert_not console.cancellable?(fresh)
    assert console.cancellable?(stuck)
  end

  test "a parent sync with incomplete children is not cancellable" do
    stub_sidekiq

    parent = Sync.create!(syncable: families(:dylan_family), status: :syncing)
    Sync.create!(syncable: accounts(:depository), status: :syncing, parent: parent)
    parent.update_columns(updated_at: 1.hour.ago)

    console = BackgroundJobConsole.new

    assert_not console.cancellable?(parent)
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
