class ImportJob < ApplicationJob
  queue_as :high_priority

  def perform(import, initiating_user: nil, initiating_user_id: nil)
    import.initiating_user = initiating_user || User.find_by(id: initiating_user_id)
    import.publish
  end
end
