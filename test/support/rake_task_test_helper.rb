# frozen_string_literal: true

# How a new test should make a rake task available.
#
# `Rails.application.load_tasks` re-reads every file in lib/tasks. Loading a
# rake file whose tasks are already defined does not replace them: Rake appends
# another action, so a task loaded twice runs its body twice per `invoke`. That
# stays invisible while the task is idempotent and the assertions only match
# patterns in its output, which a doubled run does not change.
#
# `load_tasks` also enhances the `environment` task, which reloads .env over the
# environment the test run was started with.
#
# So: load one file, only if its task is not already defined, and clear the
# `environment` prerequisite, which is already satisfied inside a test process
# and is not defined at all unless something loaded every task.
module RakeTaskTestHelper
  # Call at file scope, after `require "test_helper"`.
  def self.load_task(task_name, rake_file)
    return if Rake::Task.task_defined?(task_name)

    load Rails.root.join("lib/tasks/#{rake_file}.rake")
  end

  # Call from `setup`. Re-enabling matters because an invoked task stays
  # invoked; clearing prerequisites drops `:environment`.
  def self.prepare(*task_names)
    task_names.flatten.each do |name|
      Rake::Task[name].clear_prerequisites
      Rake::Task[name].reenable
    end
  end
end
