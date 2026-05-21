# frozen_string_literal: true

module Admin
  class SystemHealthController < Admin::BaseController
    def show
      @health = current_sidekiq_health
    end
  end
end
