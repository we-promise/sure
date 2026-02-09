module Periodable
  extend ActiveSupport::Concern

  included do
    before_action :set_period
  end

  private
    def set_period
      period_key = params[:period] || Current.user&.default_period

      @period = if period_key == "current_month"
        Period.current_month_for(Current.family)
      elsif period_key == "last_month"
        Period.last_month_for(Current.family)
      else
        Period.from_key(period_key)
      end
    rescue Period::InvalidKeyError
      @period = Period.last_30_days
    end
end
