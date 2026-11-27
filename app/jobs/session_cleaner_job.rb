class SessionCleanerJob < ApplicationJob
  queue_as :scheduled

  def perform
    deleted_count = Session.clean

    Rails.logger.info("SessionCleanerJob: Deleted #{deleted_count} sessions inactive for over #{Session::INACTIVITY_TIMEOUT.inspect}") if deleted_count > 0
  end
end
