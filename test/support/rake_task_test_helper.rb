# frozen_string_literal: true

# The one correct way to make a rake task available to a test.
#
# Three test files had grown three slightly different versions of this, and the
# differences were the bug (#93). Two called `Rails.application.load_tasks`,
# which re-reads EVERY file in lib/tasks; `load`ing a rake file whose tasks are
# already defined does not replace them, Rake APPENDS an action, so those two
# files silently gave every `loans:*` task a second action and the task body ran
# twice per `invoke`. It stayed invisible for as long as it did because those
# tasks are idempotent and the assertions on them matched patterns in output,
# which a doubled run does not change.
#
# `load_tasks` also enhances the `environment` task, which reloads .env over the
# environment the test run was started with -- a second reason a test should
# never reach for it.
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
