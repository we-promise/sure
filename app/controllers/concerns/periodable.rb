module Periodable
  extend ActiveSupport::Concern

  included do
    before_action :set_period
  end

  private
    def set_period
      if params[:start_date].present? && params[:end_date].present?
        @period = Period.custom(start_date: Date.parse(params[:start_date]), end_date: Date.parse(params[:end_date]))
        return
      end

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
    rescue Period::InvalidKeyError, ArgumentError, TypeError, ActiveModel::ValidationError
      @period = Period.last_30_days
    end
end
