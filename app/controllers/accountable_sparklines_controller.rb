class AccountableSparklinesController < ApplicationController
  def show
    @accountable = Accountable.from_type(accountable_class_name)

    @series = load_series

    render layout: false
  rescue StandardError => e
    Rails.logger.error "Accountable sparklines failed: #{e.message}"
    @series = empty_series
    render layout: false
  end

    private
      def family
        Current.family
      end

      def account_ids
        return [] unless @accountable

        scope = family.accounts.visible.where(accountable_type: @accountable.name)
        scope = installment_mode? ? scope.where(subtype: "installment") : scope.where.not(subtype: "installment")
        scope.pluck(:id)
      end

      def installment_mode?
        params[:accountable_type] == "installment"
      end

      def accountable_class_name
        installment_mode? ? "Loan" : params[:accountable_type]&.classify
      end

      def cache_key
        family.build_cache_key("#{@accountable.name}_sparkline_#{params[:accountable_type]}", invalidate_on_data_updates: true)
      end

      def load_series
        return empty_series if @accountable.blank?

        ids = account_ids
        return empty_series if ids.blank?

        Rails.cache.fetch(cache_key, expires_in: 24.hours) do
          builder = Balance::ChartSeriesBuilder.new(
            account_ids: ids,
            currency: family.currency,
            period: period,
            favorable_direction: @accountable.favorable_direction,
            interval: period.interval
          )

          builder.balance_series
        end
      end

      def empty_series
        Series.new(
          start_date: period.start_date,
          end_date: period.end_date,
          interval: period.interval,
          values: [],
          favorable_direction: @accountable&.favorable_direction || "up"
        )
      end

      def period
        @period ||= Period.last_30_days
      end
end
