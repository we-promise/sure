class Settings::LlmUsagesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "LLM Usage", nil ]
    ]
    @family = Current.family

    # Get date range from params or default to last 30 days
    def safe_parse_date(s)
      Date.iso8601(s)
    rescue ArgumentError, TypeError
      nil
    end

    private

    @end_date  = safe_parse_date(params[:end_date])  || Date.today
    @start_date = safe_parse_date(params[:start_date]) || (@end_date - 30.days)
    if @start_date > @end_date
      @start_date, @end_date = @end_date - 30.days, @end_date
    end

    # Get usage data
    @llm_usages = @family.llm_usages
                         .for_date_range(@start_date.beginning_of_day, @end_date.end_of_day)
                         .recent
                         .limit(100)

    # Get statistics
    @statistics = LlmUsage.statistics_for_family(@family, start_date: @start_date.beginning_of_day, end_date: @end_date.end_of_day)
  end
end
