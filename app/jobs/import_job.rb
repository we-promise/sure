class ImportJob < ApplicationJob
  queue_as :high_priority

  def perform(import, initiating_user: nil)
    import.initiating_user = initiating_user
    import.publish
  end
end
