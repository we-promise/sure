require "test_helper"

class Ai::GenerationRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @ids = 12.times.map { SecureRandom.uuid }
  end

  test "start! keeps the ids in order across insert slices" do
    stub_const(Ai::GenerationRun, :INSERT_SLICE, 5) do
      run = start(@ids)

      assert_equal 12, run.item_count
      assert_equal @ids, run.ids_from(0, 100).map(&:last)
      assert_equal [ [ 7, @ids[7] ], [ 8, @ids[8] ] ], run.ids_from(7, 2)
    end
  end

  test "a window takes the pending ids first, then reads on until it has a batch's worth that match" do
    run = start(@ids)
    pending = [ SecureRandom.uuid ]
    skipped = @ids.values_at(0, 2)   # already categorized, say
    window = run.window(cursor: 0, pending:, size: 3)

    matched = window.take_matching { |chunk| chunk - skipped }

    assert_equal pending + @ids.values_at(1, 3), matched
    assert_equal pending + @ids.first(4), window.examined_ids, "the skipped ids count as examined"
    assert_equal 4, window.cursor, "ids after the last one taken stay for the next job"
    assert_equal 8, window.outstanding
    assert_not window.exhausted?
  end

  test "a stretch where nothing matches is passed over inside one job" do
    stub_const(Ai::GenerationRun::Window, :CHUNK, 4) do
      run = start(@ids)
      window = run.window(cursor: 0, pending: [], size: 2)
      chunks = []

      matched = window.take_matching { |chunk| chunks << chunk.size; chunk & [ @ids.last ] }

      assert_equal [ @ids.last ], matched
      assert_equal [ 2, 4, 4, 2 ], chunks, "one batch's worth first, doubling after a short chunk"
      assert window.exhausted?
      assert_equal 0, window.outstanding
    end
  end

  test "before it's read, a window's pending ids are outstanding too" do
    run = start(@ids)

    assert_equal 2 + 7, run.window(cursor: 5, pending: @ids.first(2), size: 3).outstanding
    assert run.window(cursor: 0, pending: [], size: 3).first?
    assert_not run.window(cursor: 0, pending: @ids.first(1), size: 3).first?
  end

  test "enqueue saves the first job in the run and queues it once the run commits" do
    queued_with_run = nil
    Ai::GenerationJob.stubs(:perform_later).with { queued_with_run = Ai::GenerationRun.exists?; true }.returns(true)

    Ai::GenerationRun.transaction do
      assert Ai::GenerationRun.enqueue(:categorize, family: @family, ids: @ids, rule_run_id: nil)
      assert_nil queued_with_run, "nothing is queued before the commit"
    end

    run = Ai::GenerationRun.sole
    assert queued_with_run
    assert_equal({ "args" => { "run_id" => run.id, "cursor" => 0, "pending" => [], "step" => 0, "family_id" => @family.id },
                   "applied" => 0, "answered_before" => false }, run.next_job)
  end

  test "a first job the queue refuses, or raises on, stays saved in the run" do
    Ai::GenerationJob.stubs(:perform_later).returns(false)
    assert Ai::GenerationRun.enqueue(:categorize, family: @family, ids: @ids)

    Ai::GenerationJob.stubs(:perform_later).raises(Redis::CannotConnectError, "queue down")
    assert Ai::GenerationRun.enqueue(:categorize, family: @family, ids: @ids)

    assert_equal 2, Ai::GenerationRun.where.not(next_job: nil).count
  end

  test "a run whose transaction rolls back leaves nothing to queue" do
    Ai::GenerationJob.expects(:perform_later).never

    Ai::GenerationRun.transaction do
      Ai::GenerationRun.enqueue(:categorize, family: @family, ids: @ids)
      raise ActiveRecord::Rollback
    end

    assert_equal 0, Ai::GenerationRun.count
  end

  test "a run is undelivered once its saved step has gone an hour without a job touching it" do
    fresh = start(@ids)
    fresh.update_columns(next_job: { args: {} })
    idle = start(@ids)
    idle.update_columns(next_job: { args: {} }, updated_at: 61.minutes.ago)
    finished_step = start(@ids)
    finished_step.update_columns(updated_at: 2.hours.ago)

    assert_equal [ idle.id ], Ai::GenerationRun.undelivered.pluck(:id)
  end

  test "sweep deletes runs no job has touched in a week, however old the rest are" do
    idle = start(@ids)
    idle.update_columns(created_at: 8.days.ago, updated_at: 8.days.ago)
    long_running = start(@ids)
    long_running.update_columns(created_at: 30.days.ago, updated_at: 1.hour.ago)

    assert_equal 1, Ai::GenerationRun.sweep
    assert_equal [ long_running.id ], Ai::GenerationRun.pluck(:id)
    assert_equal 0, Ai::GenerationRun::Item.where(run_id: idle.id).count
  end

  test "a pending id whose query raises is still examined, so it's this job's to release" do
    run = start(@ids)
    window = run.window(cursor: 2, pending: @ids.first(2), size: 3)

    assert_raises(ActiveRecord::StatementInvalid) { window.take_matching { raise ActiveRecord::StatementInvalid, "lost" } }

    assert_equal @ids.first(2), window.examined_ids
    assert_equal 12, window.examined_ids.size + window.outstanding, "every id is examined or outstanding"
  end

  test "a family's runs go with it" do
    family = Family.create!(name: "Leaving")
    start(@ids, family:)

    assert_difference -> { Ai::GenerationRun.count } => -1, -> { Ai::GenerationRun::Item.count } => -12 do
      family.destroy
    end
  end

  private
    def start(ids, family: @family) = Ai::GenerationRun.start!(family:, feature: :categorize, ids:)

    def stub_const(klass, name, value)
      original = klass.const_get(name)
      klass.send(:remove_const, name)
      klass.const_set(name, value)
      yield
    ensure
      klass.send(:remove_const, name)
      klass.const_set(name, original)
    end
end
