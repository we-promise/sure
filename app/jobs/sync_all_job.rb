class SyncAllJob < ApplicationJob
  queue_as :scheduled

  def perform
    Family.find_each do |family|
      family.sync_later
    end
  end
end
