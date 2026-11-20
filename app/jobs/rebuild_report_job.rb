# Rebuilds one member's Reports view whose cached build is from older data,
# while they keep seeing that build. Queued by ReportsController#index through
# PageCache, at most once per cooldown.
class RebuildReportJob < ApplicationJob
  queue_as :low_priority

  def perform(user, query)
    ReportsController.warm_body_cache(user: user, query: query)
  end
end
