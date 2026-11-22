# frozen_string_literal: true

require "test_helper"

# Loading every task re-reads lib/tasks and appends a second action to a task
# already loaded through RakeTaskTestHelper, so its body runs twice per invoke
# depending on test order. Tests must load the one file they need instead.
class RakeTaskLoadingTest < ActiveSupport::TestCase
  test "rake task tests load only the task file they need" do
    offenders = Dir[Rails.root.join("test/**/*_test.rb")].reject do |path|
      File.expand_path(path) == File.expand_path(__FILE__)
    end.select do |path|
      File.read(path).match?(/Rails\.application\.load_tasks/)
    end

    assert_empty offenders,
      "use RakeTaskTestHelper.load_task instead of Rails.application.load_tasks: #{offenders.join(", ")}"
  end
end
