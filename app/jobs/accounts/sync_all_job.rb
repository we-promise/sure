class Accounts::SyncAllJob < ApplicationJob
  queue_as :default

  def perform
    Family.find_each do |family|
      family.sync_later
    end
  end
end
