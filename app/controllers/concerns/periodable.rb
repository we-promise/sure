module Periodable
  extend ActiveSupport::Concern

  included do
    before_action :set_period
  end

  private
    def set_period
      if params[:period].present?
        period_key = params[:period]
        Current.user&.update!(default_period: period_key) if Period.valid_key?(period_key)
      else
        period_key = Current.user&.default_period
      end

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
