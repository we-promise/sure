# Rebuilds one member's Reports view whose cached build is from older data,
# while they keep seeing that build. Queued by ReportsController#index through
# PageCache, at most once per cooldown.
class RebuildReportJob < ApplicationJob
  queue_as :low_priority

  # `locale` keeps the rebuild in the language the stale build was made in.
  def perform(user, query, locale = nil)
    ReportsController.warm_body_cache(user: user, query: query, locale: locale)
  end
end
