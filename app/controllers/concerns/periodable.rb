module Periodable
  extend ActiveSupport::Concern

  included do
    before_action :set_period
  end

  private
    def set_period
      key = params[:period] || Current.user&.default_period

      if key == "current_month" && Current.family&.uses_custom_month_start?
        @period = Current.family.current_custom_month_period
      elsif key == "last_month" && Current.family&.uses_custom_month_start?
        @period = Period.last_month_for(Current.family)
      else
        @period = Period.from_key(key)
      end
    rescue Period::InvalidKeyError
      @period = Period.last_30_days
    end
end
