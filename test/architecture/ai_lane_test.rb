require "test_helper"

# Every AI job runs on its lane's queue (Ai::Routes::QUEUES) and in that lane (Ai::Sequencer),
# and the queue names live only in Ai::Routes.
class AiLaneTest < ActiveSupport::TestCase
  class LaneJob < ApplicationJob
    def perform = Fiber[:ai_lane]
  end

  test "every AI job is queued on its feature's lane" do
    jobs = {
      AssistantResponseJob.new => :chat,
      ProcessPdfJob.new => :extract_pdf,
      IndexAccountStatementJob.new => :embed,
      IndexFamilyDocumentJob.new => :embed,
      VectorStore::IndexStatusJob.new => :embed,
      VectorStore::PurgeDocumentFileJob.new => :embed,
      VectorStore::RequeueIndexPollsJob.new => :embed,
      Ai::ShadowJob.new(:categorize) => :shadow_categorize
    }
    Ai::Routes.features.each { |feature| jobs[Ai::GenerationJob.new(feature)] = feature }

    jobs.each do |job, feature|
      assert_equal Ai::Routes::QUEUES.fetch(Ai::Routes.fetch(feature)[:lane]), job.queue_name, "#{job.class.name} (#{feature})"
    end
    assert_equal Ai::Routes::QUEUES.fetch(:background), Ai::ProbeJob.new.queue_name
  end

  test "no job names an AI queue itself" do
    names = Ai::Routes.ai_queues.join("|")
    (Rails.root.glob("app/{jobs,models}/**/*.rb") - [ Rails.root.join("app/models/ai/routes.rb") ]).each do |file|
      assert_no_match(/(queue_as|queue:|Queue\.new\()\s*[:"'](#{names})\b/, file.read, "#{file.relative_path_from(Rails.root)} names an AI queue; use Ai::Routes.queue_for")
    end
  end

  test "a scheduled job on an AI queue is scheduled on the queue it names, never a legacy one" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))
    ai = schedule.values.select { Ai::Routes.ai_queues.include?(_1["queue"]) }

    assert_not_empty ai
    ai.each do |entry|
      assert_includes Ai::Routes::QUEUES.values, entry["queue"]
      assert_equal entry["class"].constantize.new.queue_name, entry["queue"], entry["class"]
    end
  end

  test "a job runs in its queue's lane, a legacy queue's job in the lane it moved to, other jobs in none" do
    lanes = %w[ai_interactive ai_prompt ai_background ai_high_priority ai_low_priority default].to_h do |queue|
      [ queue, LaneJob.set(queue:).perform_now ]
    end

    assert_equal({ "ai_interactive" => :interactive, "ai_prompt" => :prompt, "ai_background" => :background,
                   "ai_high_priority" => :interactive, "ai_low_priority" => :prompt, "default" => nil }, lanes)
  end

  test "a call outside any lane counts as interactive, and with_lane nests" do
    assert_equal :interactive, Ai::Sequencer.lane

    Ai::Sequencer.with_lane(:prompt) do
      Ai::Sequencer.with_lane(:background) { assert_equal :background, Ai::Sequencer.lane }
      Ai::Sequencer.with_lane(nil) { assert_equal :prompt, Ai::Sequencer.lane }
      assert_raises(ArgumentError) { Ai::Sequencer.with_lane(:urgent) { } }
      assert_equal :prompt, Ai::Sequencer.lane
    end
    assert_nil Fiber[:ai_lane]
  end

  # Down marks: someone waits in the interactive lane, so a call there tries routes every one of
  # which is marked down; prompt and background jobs fail at once and wait the mark out.
  { interactive: 1, prompt: 0, background: 0 }.each do |lane, sent|
    test "with every route marked down, a call in the #{lane} lane sends #{sent} request#{"s" unless sent == 1}" do
      use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
      Ai::DownMarks.stubs(:state).returns(:passing)
      requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
      generation = AiTestGeneration.new(transactions: [ { id: "t1", description: "AMZN", merchant: nil } ], family: families(:dylan_family))

      result = Ai::Sequencer.with_lane(lane) { generation.call(batches: 1) }

      assert_equal sent, requests.size
      assert_kind_of Ai::Error::MarkedDown, result.error if sent.zero?
    end
  end

  test "a job on the interactive queue tries past down marks; one on the background queue doesn't" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
    Ai::DownMarks.stubs(:state).returns(:passing)
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    job = Class.new(ApplicationJob) do
      def perform = AiTestGeneration.new(transactions: [ { id: "t1", description: "AMZN", merchant: nil } ], family: Family.first).call(batches: 1)
    end

    assert job.set(queue: Ai::Routes::QUEUES.fetch(:interactive)).perform_now.success?
    assert_kind_of Ai::Error::MarkedDown, job.set(queue: Ai::Routes::QUEUES.fetch(:background)).perform_now.error
    assert_equal 1, requests.size
  end
end
