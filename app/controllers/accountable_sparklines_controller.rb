class AccountableSparklinesController < ApplicationController
  def show
    @accountable = Accountable.from_type(accountable_class_name)

    etag_key = cache_key

    # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
    if stale?(etag: etag_key, last_modified: family.latest_sync_completed_at)
      @series = Rails.cache.fetch(etag_key, expires_in: 24.hours) do
        builder = Balance::ChartSeriesBuilder.new(
          account_ids: account_ids,
          currency: family.currency,
          period: Period.last_30_days,
          favorable_direction: @accountable.favorable_direction,
          interval: "1 day"
        )

        builder.balance_series
      end

      render layout: false
    end
  end

    private
      def family
        Current.family
      end

      def account_ids
        scope = family.accounts.visible.where(accountable_type: @accountable.name)
        scope = installment_mode? ? scope.where(id: installment_account_ids) : scope.where.not(id: installment_account_ids)
        scope.pluck(:id)
      end

      def installment_account_ids
        @installment_account_ids ||= family.accounts.joins(:installment).pluck(:id)
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
end
