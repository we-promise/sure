require "test_helper"

# The generation outbox reports batches and the run's end through the requester. A replayed step,
# a second copy or a redelivered step must never make the requester hear the end twice.
class AiCompletionHookTest < ActiveJob::TestCase
  class Requester
    include Ai::Requester

    class << self
      attr_accessor :feature, :log

      def from_ai_job(window:, family_id:, **) = new(feature, window, Family.find(family_id))
    end

    def initialize(feature, window, family)
      @feature, @window, @family = feature, window, family
    end

    def ai_generation
      ids = @window.take_matching { _1 }
      return if ids.empty?

      transactions = ids.map { |id| { id:, description: "SHOP #{id}", merchant: nil } }
      AiTestGeneration.new(transactions:, family: @family)
    end

    def apply_ai(result)
      count = result.value[:merchants].size
      self.class.log << [ @feature, :applied, count ]
      count
    end

    def ai_finished(count) = self.class.log << [ @feature, :finished, count ]
    def ai_failed(error) = self.class.log << [ @feature, :failed, error.class ]
  end

  FEATURES = %i[bill_setup categorize detect_merchants enhance_merchants].freeze

  setup do
    Requester.log = []
    Ai::Requesters.stubs(:fetch).returns(Requester)
    @family = families(:dylan_family)
    use_ai_routes
    use_ai_model_settings(batch_size: 2)
  end

  def run_queue
    until enqueued_jobs.empty?
      job = enqueued_jobs.shift
      ActiveJob::Base.execute(job.stringify_keys)
    end
  end

  def ids_for(feature)
    Array.new(3) { |index| Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, "#{feature}-#{index}") }
  end

  def start_run(feature)
    Requester.feature = feature
    Requester.log = []
    clear_enqueued_jobs
    Ai::GenerationJob.perform_later(feature, ai_run_args(feature, ids: ids_for(feature), family: @family))
  end

  def applied(log, feature) = log.select { |entry| entry[0] == feature && entry[1] == :applied }
  def endings(log, feature) = log.select { |entry| entry[0] == feature && entry[1].in?(%i[finished failed]) }

  test "every registered requester declares its feature and applies AI" do
    Ai::Requesters::CLASSES.each do |feature, name|
      requester = name.constantize

      assert_equal feature, requester.ai_feature
      assert_includes requester.instance_methods, :apply_ai
    end
  end

  test "each feature reports once per applied batch and finishes once per run" do
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    FEATURES.each do |feature|
      start_run(feature)
      run_queue

      assert_equal [ 2, 1 ], applied(Requester.log, feature).map { _1.last }, feature
      assert_equal [ [ feature, :finished, 3 ] ], endings(Requester.log, feature), feature
      assert_equal 0, Ai::GenerationRun.count, feature
    end
  end

  test "a failed run tells each feature's requester once" do
    stub_ai(:detect_merchants, raises: Ai::Error::Refused)

    FEATURES.each do |feature|
      start_run(feature)
      run_queue

      assert_empty applied(Requester.log, feature), feature
      assert_equal [ [ feature, :failed, Ai::Error::Refused ] ], endings(Requester.log, feature), feature
      assert_equal 0, Ai::GenerationRun.count, feature
    end
  end

  test "an outbox-redelivered run still reports ai_finished once" do
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    start_run(:detect_merchants)
    Ai::GenerationJob.stubs(:perform_later).returns(false)

    ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys)
    assert_equal [ [ :detect_merchants, :applied, 2 ] ], Requester.log

    Ai::GenerationJob.unstub(:perform_later)
    Ai::GenerationRun.update_all(updated_at: 61.minutes.ago)
    Ai::GenerationDeliveryJob.perform_now
    run_queue

    assert_equal [ [ :detect_merchants, :applied, 2 ], [ :detect_merchants, :applied, 1 ],
                   [ :detect_merchants, :finished, 3 ] ], Requester.log
  end
end
