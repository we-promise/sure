# frozen_string_literal: true

module Admin
  class SystemHealthController < Admin::BaseController
    # Bypass the per-request memo / cross-request cache that the layout
    # banner uses. An operator landing on this page (often right after
    # restarting the worker) wants to confirm the current state, not a
    # snapshot up to `SidekiqHealth::CACHE_TTL` old. Also makes the page
    # work in managed mode, where `current_sidekiq_health` is nil.
    def show
      SidekiqHealth.expire_cache!
      @health = SidekiqHealth.new
    end
  end
end
