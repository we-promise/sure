# frozen_string_literal: true

module Admin
  class SystemHealthController < Admin::BaseController
    def show
      @health = SidekiqHealth.new
    end
  end
end
