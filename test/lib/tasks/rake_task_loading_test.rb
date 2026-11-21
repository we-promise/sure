# frozen_string_literal: true

require "test_helper"

# Loading every rake file a second time appends a second action to each task
# already defined, so a task loaded through RakeTaskTestHelper runs its body
# twice in any worker where a test that loads every task ran first. See
# test/support/rake_task_test_helper.rb.
class RakeTaskLoadingTest < ActiveSupport::TestCase
  test "no test loads every rake task" do
    offenders = Dir[Rails.root.join("test/**/*_test.rb")].select do |path|
      File.read(path).match?(/Rails\.application\.load_tasks/)
    end

    assert_empty offenders.map { |path| Pathname(path).relative_path_from(Rails.root).to_s },
      "load one rake file with RakeTaskTestHelper.load_task instead"
  end
end
