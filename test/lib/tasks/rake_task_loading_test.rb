# frozen_string_literal: true

require "test_helper"

# Loading every rake file a second time appends a second action to each task
# already defined, so a task loaded through RakeTaskTestHelper runs its body
# twice in any worker where a test that loads every task ran first. See
# test/support/rake_task_test_helper.rb.
class RakeTaskLoadingTest < ActiveSupport::TestCase
  LOAD_EVERY_TASK = /Rails\s*\.\s*application\s*\.\s*load_tasks\b/

  test "no test loads every rake task" do
    offenders = Dir[Rails.root.join("test/**/*_test.rb")].select do |path|
      File.read(path).match?(LOAD_EVERY_TASK)
    end

    assert_empty offenders.map { |path| Pathname(path).relative_path_from(Rails.root).to_s },
      "load one rake file with RakeTaskTestHelper.load_task instead"
  end

  test "the check finds a call split across lines and nothing else" do
    assert_match LOAD_EVERY_TASK, "Rails\n  .application\n  .load_tasks"
    assert_match LOAD_EVERY_TASK, "Rails.\n  application.\n  load_tasks"
    assert_no_match LOAD_EVERY_TASK, "RakeTaskTestHelper.load_task"
    assert_no_match LOAD_EVERY_TASK, File.read(__FILE__)
  end
end
