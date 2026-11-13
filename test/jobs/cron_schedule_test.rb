require "test_helper"

# Regression coverage for https://github.com/we-promise/sure/issues/1442 - when
# the process firing a cron tick couldn't resolve the job class, sidekiq-cron
# pushed a raw Sidekiq::Job payload and the worker crashed with
# `undefined method 'jid='` because every scheduled class is an ActiveJob.
class CronScheduleTest < ActiveSupport::TestCase
  SCHEDULE = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))
  JOB_WRAPPER = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"

  test "every scheduled job is an ActiveJob flagged with active_job: true" do
    SCHEDULE.each do |name, config|
      assert config["class"].constantize < ApplicationJob, "#{name}: #{config["class"]} must be an ApplicationJob"
      assert_equal true, config["active_job"], "#{name}: set `active_job: true` so sidekiq-cron always enqueues an ActiveJob payload"
    end
  end

  test "cron ticks enqueue an ActiveJob wrapper even when the job class can't be resolved" do
    Sidekiq::Cron::Support.stubs(:safe_constantize).returns(nil)
    Sidekiq::Cron::Job.any_instance.stubs(:save_last_enqueue_time)
    Sidekiq::Cron::Job.any_instance.stubs(:add_jid_history)

    SCHEDULE.each do |name, config|
      job = Sidekiq::Cron::Job.new(config.merge("name" => name, "status" => "enabled", "last_enqueue_time" => Time.current.to_s))

      Sidekiq::Client.expects(:push).with do |payload|
        payload["class"] == JOB_WRAPPER &&
          payload["wrapped"] == config["class"] &&
          payload["queue"] == config["queue"] &&
          payload["args"].first["job_class"] == config["class"]
      end.returns("jid")

      job.enqueue!
    end
  end
end
