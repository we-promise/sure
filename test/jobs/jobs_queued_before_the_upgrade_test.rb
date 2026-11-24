require "test_helper"

# Jobs main queued under classes the AI plumbing replaced still run after the upgrade, with the
# arguments main gave them, and a rule run waiting on one ends once.
class JobsQueuedBeforeTheUpgradeTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @transaction = @family.transactions.first
    # As main's runner left it: the job counted, nothing else waited for.
    @rule_run = RuleRun.create!(rule: rules(:one), rule_name: "Rule", execution_type: "manual", status: "pending",
                                transactions_queued: 1, transactions_processed: 1, transactions_modified: 0,
                                pending_jobs_count: 1, executed_at: Time.current)
  end

  { AutoCategorizeJob => :categorize, AutoDetectMerchantsJob => :detect_merchants }.each do |job_class, feature|
    test "#{job_class.name} from main starts the #{feature} run for its rule run, without counting it again" do
      job_class.perform_now(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)

      queued = enqueued_jobs.sole
      assert_equal "Ai::GenerationJob", queued["job_class"]
      feature_arg, args = ActiveJob::Arguments.deserialize(queued["arguments"])
      assert_equal feature, feature_arg.to_sym
      assert_equal @rule_run.id, args[:rule_run_id]
      assert_equal [ @transaction.id ], Ai::GenerationRun.find(args[:run_id]).items.pluck(:item_id)
      assert_equal 1, @rule_run.reload.pending_jobs_count, "main already counted this job"
    end

    test "#{job_class.name} from main ends its rule run once when the AI run ends" do
      use_no_ai

      perform_enqueued_jobs do
        job_class.perform_now(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
      end

      @rule_run.reload
      assert_equal 0, @rule_run.pending_jobs_count
      assert_not @rule_run.pending?, "the rule run doesn't stay pending"
    end

    test "#{job_class.name} from main fails its rule run once when the #{feature} run can't be queued" do
      [ -> { false }, -> { raise Errno::ECONNREFUSED } ].each do |refusal|
        @rule_run.update!(status: "pending", pending_jobs_count: 2, error_message: nil)
        tries = 0
        stub_enqueue = ->(*) { tries += 1; refusal.call }

        with_generation_enqueue(stub_enqueue) do
          perform_enqueued_jobs(only: job_class) do
            job_class.perform_later(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
          end
        end

        assert_equal 5, tries
        @rule_run.reload
        assert_equal "failed", @rule_run.status
        assert_equal 1, @rule_run.pending_jobs_count, "the run's other job is still out"
        assert_includes @rule_run.error_message, "couldn't be queued"
        assert_empty Ai::GenerationRun.where(family: @family)
      end
    end
  end

  test "EnhanceProviderMerchantsJob from main starts a merchant enhancement" do
    Ai::GenerationRun.expects(:enqueue).with(:enhance_merchants, has_entries(family: @family)).returns(true)

    EnhanceProviderMerchantsJob.perform_now(@family, merchant_ids: [ "a" ])
  end

  test "WorkerAiHealthCheckJob from main queues the AI probes" do
    assert_enqueued_with(job: Ai::ProbeJob) { WorkerAiHealthCheckJob.perform_now }
  end

  test "WorkerAiHealthCheckJob from main raises, so it's retried, when the AI probes can't be queued" do
    Ai::ProbeJob.stubs(:perform_later).returns(false)

    assert_raises(ActiveJob::EnqueueError) { WorkerAiHealthCheckJob.perform_now }
  end

  private
    # Mocha can't run a block per call, and the tries must be counted.
    def with_generation_enqueue(stub)
      Ai::GenerationJob.singleton_class.define_method(:perform_later) { |*args, **options| stub.call(*args, **options) }
      yield
    ensure
      Ai::GenerationJob.singleton_class.remove_method(:perform_later)
    end
end
