# The price history chart in a holding's drawer: the security's stored closes
# over the picked period. It renders in its own frame, so picking a period
# reloads the chart and leaves the rest of the drawer as it is.
class HoldingPriceChartsController < ApplicationController
  include Periodable

  before_action :set_holding

  def show
    @series = @holding.security.price_series(period: @period)
    # Prices are only stored from when the security was first held, so a
    # long period can start before the first close.
    @comparison_label = if @series && @series.start_date > @period.start_date
      t(".vs_available_history")
    else
      @period.comparison_label
    end
  end

  private
    def set_holding
      @holding = Current.family.holdings
                   .joins(:account)
                   .merge(Account.accessible_by(Current.user))
                   .find(params[:holding_id])
    end
end
