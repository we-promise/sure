require "test_helper"

class Ai::GenerationJobTest < ActiveJob::TestCase
  # A requester over AiTestGeneration that records what the job tells it.
  class Requester
    include Ai::Requester
    ai_feature :detect_merchants

    class << self
      attr_accessor :log
    end

    def self.from_ai_job(ids:, family_id:, **) = new(ids, Family.find(family_id))

    def initialize(ids, family)
      @ids, @family = ids, family
    end

    def ai_generation
      return if @ids.empty?

      transactions = @ids.map { { id: _1, description: "SHOP #{_1}", merchant: nil } }
      AiTestGeneration.new(transactions:, family: @family)
    end

    def apply_ai(result)
      self.class.log << [ :applied, @family.id, result.value[:merchants].map { _1[:transaction_id] } ]
      result.value[:merchants].size
    end

    def ai_finished(count) = self.class.log << [ :finished, @family.id, count ]
    def ai_failed(error) = self.class.log << [ :failed, @family.id, error.class ]
  end

  setup do
    Requester.log = []
    Ai::Requesters.overrides[:detect_merchants] = Requester
    @family = families(:dylan_family)
    use_ai_routes
  end

  teardown { Ai::Requesters.overrides.clear }

  def run_queue
    until enqueued_jobs.empty?
      job = enqueued_jobs.shift
      ActiveJob::Base.execute(job.stringify_keys)
    end
  end

  test "runs one batch per job and enqueues the rest at the back, then finishes once" do
    with_ai_model_settings(batch_size: 2) do
      stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

      Ai::GenerationJob.perform_later(:detect_merchants, { ids: %w[a b c d e], family_id: @family.id })
      assert_equal "ai_low_priority", enqueued_jobs.first["queue_name"]
      run_queue

      assert_equal [ [ :applied, @family.id, %w[a b] ], [ :applied, @family.id, %w[c d] ], [ :applied, @family.id, %w[e] ],
                     [ :finished, @family.id, 5 ] ], Requester.log
    end
  end

  test "nothing to do finishes with zero and makes no call" do
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    Ai::GenerationJob.perform_now(:detect_merchants, { ids: [], family_id: @family.id })

    assert_equal [ [ :finished, @family.id, 0 ] ], Requester.log
    assert_empty requests
  end

  test "a feature that became unavailable is discarded, and the requester hears once" do
    without_ai do
      Ai::GenerationJob.perform_now(:detect_merchants, { ids: %w[a], family_id: @family.id })
    end

    assert_equal [ [ :failed, @family.id, Ai::Error::Unavailable ] ], Requester.log
  end

  test "invalid output on every route is discarded" do
    stub_ai(:detect_merchants, raises: Ai::Error::InvalidOutput.new("no"))

    Ai::GenerationJob.perform_now(:detect_merchants, { ids: %w[a], family_id: @family.id })

    assert_equal [ [ :failed, @family.id, Ai::Error::InvalidOutput ] ], Requester.log
  end

  test "a timeout is retried later, and the requester hears only when the retries run out" do
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout.new("slow"))

    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      Ai::GenerationJob.perform_now(:detect_merchants, { ids: %w[a], family_id: @family.id })
    end
    assert_empty Requester.log
  end

  test "a timeout that outlasts every retry tells the requester once" do
    stub_ai(:detect_merchants, raises: Ai::Error::Timeout.new("slow"))

    Ai::GenerationJob.perform_later(:detect_merchants, { ids: %w[a], family_id: @family.id })
    run_queue

    assert_equal [ [ :failed, @family.id, Ai::Error::Timeout ] ], Requester.log
  end

  test "any other error ends the run and tells the requester once" do
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    Requester.any_instance.stubs(:apply_ai).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_no_enqueued_jobs only: Ai::GenerationJob do
      Ai::GenerationJob.perform_now(:detect_merchants, { ids: %w[a], family_id: @family.id })
    end
    assert_equal [ [ :failed, @family.id, ActiveRecord::StatementInvalid ] ], Requester.log
  end

  test "a job queued under an old class is handed to Ai::GenerationJob" do
    assert_enqueued_with(job: Ai::GenerationJob, args: [ :categorize, { ids: %w[a], family_id: @family.id, rule_run_id: "r1" } ]) do
      AutoCategorizeJob.perform_now(@family, transaction_ids: %w[a], rule_run_id: "r1")
    end
    assert_enqueued_with(job: Ai::GenerationJob, args: [ :detect_merchants, { ids: %w[b], family_id: @family.id } ]) do
      AutoDetectMerchantsJob.perform_now(@family, transaction_ids: %w[b])
    end
    assert_enqueued_with(job: Ai::GenerationJob, args: [ :enhance_merchants, { family_id: @family.id, ids: %w[m] } ]) do
      EnhanceProviderMerchantsJob.perform_now(@family, merchant_ids: %w[m])
    end
  end

  test "an interactive feature's job goes to today's high-priority queue" do
    assert_equal "ai_high_priority", Ai::Routes.queue_for(:bill_setup)
    assert_equal "ai_low_priority", Ai::Routes.queue_for(:categorize)
  end

  # Fairness: on one AI thread against a cloud endpoint, two families'
  # large runs take turns, so each gets its first result before either finishes.
  test "two families' runs on one thread each get a result before either finishes" do
    other = families(:empty)
    with_ai_model_settings(batch_size: 2) do
      stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

      Ai::GenerationJob.perform_later(:detect_merchants, { ids: %w[a1 a2 a3 a4 a5 a6], family_id: @family.id })
      Ai::GenerationJob.perform_later(:detect_merchants, { ids: %w[b1 b2 b3 b4 b5 b6], family_id: other.id })
      run_queue
    end

    first_applied = ->(family) { Requester.log.index { _1[0] == :applied && _1[1] == family.id } }
    finished = ->(family) { Requester.log.index { _1[0] == :finished && _1[1] == family.id } }
    assert_operator first_applied.(other), :<, finished.(@family)
    assert_operator first_applied.(@family), :<, finished.(other)
  end
end
