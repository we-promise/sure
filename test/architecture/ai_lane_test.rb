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
      VectorStore::IndexStatusJob.new => :embed,
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
end
