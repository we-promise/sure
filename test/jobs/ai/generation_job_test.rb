require "test_helper"

class Ai::GenerationJobTest < ActiveJob::TestCase
  # Runs hold uuids; the tests name items by label.
  ID = Hash.new { |ids, label| ids[label] = Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, label) }
  LABEL = ->(id) { ID.key(id) }

  # A requester over AiTestGeneration that records what the job tells it. Every id matches.
  class Requester
    include Ai::Requester
    ai_feature :detect_merchants

    class << self
      attr_accessor :log
    end

    def self.from_ai_job(window:, family_id:, **) = new(window, Family.find(family_id))

    def initialize(window, family)
      @window, @family = window, family
    end

    def ai_generation
      ids = @window.take_matching { _1 }
      return if ids.empty?

      transactions = ids.map { { id: _1, description: "SHOP #{LABEL.(_1)}", merchant: nil } }
      AiTestGeneration.new(transactions:, family: @family)
    end

    def apply_ai(result)
      self.class.log << [ :applied, @family.id, result.value[:merchants].map { LABEL.(_1[:transaction_id]) } ]
      result.value[:merchants].size
    end

    def ai_finished(count) = self.class.log << [ :finished, @family.id, count ]
    def ai_failed(error) = self.class.log << [ :failed, @family.id, error.class ]
  end

  setup do
    Requester.log = []
    Ai::Requesters.stubs(:fetch).returns(Requester)
    @family = families(:dylan_family)
    use_ai_routes
  end

  def run_queue
    until enqueued_jobs.empty?
      job = enqueued_jobs.shift
      ActiveJob::Base.execute(job.stringify_keys)
    end
  end

  test "runs one batch per job and enqueues the rest at the back, then finishes once" do
    use_ai_model_settings(batch_size: 2)
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c d e]), family: @family))
    assert_equal "ai_low_priority", enqueued_jobs.first["queue_name"]
    run_queue

    assert_equal [ [ :applied, @family.id, %w[a b] ], [ :applied, @family.id, %w[c d] ], [ :applied, @family.id, %w[e] ],
                   [ :finished, @family.id, 5 ] ], Requester.log
    assert_equal 0, Ai::GenerationRun.count, "the run is deleted once the requester has heard"
  end

  test "each job carries a cursor and the last batch's leftovers, never the rest of the run" do
    use_ai_model_settings(batch_size: 2)
    AiTestGeneration.any_instance.stubs(:call).returns(
      Ai::Result.new(value: { merchants: [ { transaction_id: ID["a"], business_name: "A", business_url: "a.test" } ] },
                     remaining: [ { id: ID["b"] } ])
    )

    Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c d e]), family: @family))

    next_args = enqueued_jobs.sole["arguments"].second
    assert_equal 2, next_args["cursor"]
    assert_equal [ ID["b"] ], next_args["pending"]
    assert_not next_args.key?("ids")
  end

  test "a replayed job whose step committed queues the saved next job instead of applying its batch again" do
    use_ai_model_settings(batch_size: 2)
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c]), family: @family))
    first = enqueued_jobs.shift.stringify_keys

    ActiveJob::Base.execute(first)
    ActiveJob::Base.execute(first)   # Sidekiq replays it: the worker died before the job was acknowledged

    assert_equal 2, enqueued_jobs.size, "the replay queued the next step again, since it hadn't started"
    run_queue
    assert_equal [ [ :applied, @family.id, %w[a b] ], [ :applied, @family.id, %w[c] ], [ :finished, @family.id, 3 ] ], Requester.log
  end

  test "a replay of a step whose next step has started queues nothing" do
    use_ai_model_settings(batch_size: 1)
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c]), family: @family))
    first = enqueued_jobs.shift.stringify_keys
    ActiveJob::Base.execute(first)
    second = enqueued_jobs.shift.stringify_keys
    ActiveJob::Base.execute(second)
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout)
    ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys)   # step 2 starts, times out, and is retried later
    assert_equal 1, enqueued_jobs.size

    ActiveJob::Base.execute(first)    # behind the run: step 1 has committed since
    ActiveJob::Base.execute(second)   # the latest committed step, but the step it queued has started

    assert_equal 1, enqueued_jobs.size, "only step 2's retry"
    assert_equal [ [ :applied, @family.id, %w[a] ], [ :applied, @family.id, %w[b] ] ], Requester.log
  end

  test "a copy of a job that loses its step to another copy applies nothing and queues nothing" do
    use_ai_model_settings(batch_size: 2)
    stub_ai(:detect_merchants) do |request|
      Ai::GenerationRun.update_all(step: 1)   # the other copy commits step 0 while this one waits for its answer
      AiTestGeneration.answer(request)
    end

    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c]), family: @family))
    ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys)

    assert_empty Requester.log
    assert_empty enqueued_jobs
    assert_equal 1, Ai::GenerationRun.count, "the other copy carries the run on"
  end

  test "a give-up that deadlocks leaves the run, so the retry gives up once" do
    stub_ai(:detect_merchants, raises: Ai::Error::Refused)
    attempts = 0
    Requester.define_method(:ai_failed) do |error|
      attempts += 1
      raise ActiveRecord::Deadlocked, "deadlock detected" if attempts == 1

      self.class.log << [ :failed, @family.id, error.class ]
    end
    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at("a"), family: @family))
    job = enqueued_jobs.shift.stringify_keys

    assert_raises(ActiveRecord::Deadlocked) { ActiveJob::Base.execute(job) }
    assert_equal 1, Ai::GenerationRun.count
    ActiveJob::Base.execute(job)

    assert_equal [ [ :failed, @family.id, Ai::Error::Refused ] ], Requester.log
    assert_equal 0, Ai::GenerationRun.count
  ensure
    Requester.define_method(:ai_failed) { |error| self.class.log << [ :failed, @family.id, error.class ] }
  end

  test "a job whose run already ended is dropped without telling the requester again" do
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    args = ai_run_args(:detect_merchants, ids: [ ID["a"] ], family: @family)
    Ai::GenerationRun.find(args[:run_id]).destroy

    assert_nothing_raised { Ai::GenerationJob.perform_now(:detect_merchants, args) }
    assert_empty Requester.log
    assert_empty requests
  end

  test "once a batch was answered, a later batch whose answers are unusable is skipped, not the run" do
    use_ai_model_settings(batch_size: 1)
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::InvalidOutput, "garbage" if request.input.include?("SHOP b")

      AiTestGeneration.answer(request)
    end

    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c]), family: @family))
    run_queue

    assert_equal [ [ :applied, @family.id, %w[a] ], [ :applied, @family.id, [] ], [ :applied, @family.id, %w[c] ],
                   [ :finished, @family.id, 2 ] ], Requester.log
  end

  test "a next batch that can't be queued tells the requester" do
    use_ai_model_settings(batch_size: 1)
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    Ai::GenerationJob.stubs(:perform_later).returns(false)

    Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b]), family: @family))

    assert_equal [ [ :applied, @family.id, %w[a] ], [ :failed, @family.id, ActiveJob::EnqueueError ] ], Requester.log
    assert_equal 0, Ai::GenerationRun.count
  end

  test "a feature that became unavailable is discarded, and the requester hears once" do
    use_no_ai
    Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a]), family: @family))

    assert_equal [ [ :failed, @family.id, Ai::Error::Unavailable ] ], Requester.log
  end

  test "invalid output on every route is discarded" do
    stub_ai(:detect_merchants, raises: Ai::Error::InvalidOutput.new("no"))

    Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a]), family: @family))

    assert_equal [ [ :failed, @family.id, Ai::Error::InvalidOutput ] ], Requester.log
  end

  test "a timeout is retried later on the same window, and the requester hears only when the retries run out" do
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout.new("slow"))

    args = ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a b c]), family: @family)
    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      Ai::GenerationJob.perform_now(:detect_merchants, args)
    end
    assert_empty Requester.log
    assert_equal args, ActiveJob::Arguments.deserialize(enqueued_jobs.sole["arguments"]).second, "the retry reads the same window"
  end

  test "a retry that can't be queued tells the requester instead of leaving it waiting" do
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout.new("slow"))
    Ai::GenerationJob.any_instance.stubs(:enqueue).returns(false)   # the queue refuses the retry

    Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a]), family: @family))

    assert_equal [ [ :failed, @family.id, Ai::Error::Timeout ] ], Requester.log
  end

  test "a retry whose enqueue raises tells the requester instead of leaving it waiting" do
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout.new("slow"))
    Ai::GenerationJob.any_instance.stubs(:enqueue).raises(Redis::CannotConnectError, "queue down")

    Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a]), family: @family))

    assert_equal [ [ :failed, @family.id, Ai::Error::Timeout ] ], Requester.log
  end

  test "a timeout that outlasts every retry tells the requester once" do
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout.new("slow"))

    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a]), family: @family))
    run_queue

    assert_equal [ [ :failed, @family.id, Ai::Error::Timeout ] ], Requester.log
  end

  test "any other error ends the run and tells the requester once" do
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    Requester.any_instance.stubs(:apply_ai).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_no_enqueued_jobs only: Ai::GenerationJob do
      Ai::GenerationJob.perform_now(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a]), family: @family))
    end
    assert_equal [ [ :failed, @family.id, ActiveRecord::StatementInvalid ] ], Requester.log
  end

  test "a job whose family was deleted while it waited is dropped, not retried" do
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    assert_nothing_raised do
      Ai::GenerationJob.perform_now(:detect_merchants, { ids: ID.values_at(*%w[a]), family_id: SecureRandom.uuid })
    end
    assert_empty Requester.log
    assert_empty requests
  end

  test "a stale job for a feature no longer registered drops once, quietly" do
    Ai::Requesters.stubs(:fetch).raises(KeyError)

    assert_nothing_raised do
      # A queued job carries its queue; a new one would ask the routes for the gone feature's.
      Ai::GenerationJob.set(queue: "ai_low_priority").perform_now(:retirement_planner, { ids: ID.values_at(*%w[a]), family_id: @family.id })
    end
  end

  # Fairness: on one AI thread against a cloud endpoint, two families'
  # large runs take turns, so each gets its first result before either finishes.
  test "two families' runs on one thread each get a result before either finishes" do
    other = families(:empty)
    use_ai_model_settings(batch_size: 2)
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[a1 a2 a3 a4 a5 a6]), family: @family))
    Ai::GenerationJob.perform_later(:detect_merchants, ai_run_args(:detect_merchants, ids: ID.values_at(*%w[b1 b2 b3 b4 b5 b6]), family: other))
    run_queue

    first_applied = ->(family) { Requester.log.index { _1[0] == :applied && _1[1] == family.id } }
    finished = ->(family) { Requester.log.index { _1[0] == :finished && _1[1] == family.id } }
    assert_operator first_applied.(other), :<, finished.(@family)
    assert_operator first_applied.(@family), :<, finished.(other)
  end
end
