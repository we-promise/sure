require "test_helper"

# Every AI job runs on its lane's queue (Ai::Routes::QUEUES), and the queue names live only in
# Ai::Routes.
class AiLaneTest < ActiveSupport::TestCase
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
end
