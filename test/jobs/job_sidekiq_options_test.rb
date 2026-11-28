require "test_helper"

# sidekiq-unique-jobs cannot lock ActiveJob jobs: the gem does not support
# ActiveJob and its digest includes the random job_id. A `lock:` option on an
# ApplicationJob is therefore inert and must not be declared.
class JobSidekiqOptionsTest < ActiveSupport::TestCase
  test "no job declares an inert sidekiq-unique-jobs lock" do
    Rails.application.eager_load!

    offenders = ApplicationJob.descendants.filter_map do |job|
      (job.name || job.inspect) if job.get_sidekiq_options.key?("lock")
    end

    assert_empty offenders, "ActiveJob jobs cannot be locked by sidekiq-unique-jobs"
  end
end
