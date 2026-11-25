class ImportJob < ApplicationJob
  queue_as :high_priority

  def perform(import, publish_token: nil)
    import.publish(publish_token:)
  end
end
