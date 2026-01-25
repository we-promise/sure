class Settings::LlmUsagesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.llm_usages"), nil ]
    ]

    @start_date = safe_parse_date(params[:start_date]) || 30.days.ago.to_date
    @end_date = safe_parse_date(params[:end_date]) || Date.current

    @llm_usages = Current.family.llm_usages
                         .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day)
                         .order(created_at: :desc)

    @statistics = LlmUsage.statistics_for_collection(@llm_usages, currency: Current.family.currency)
  end

  private
    def safe_parse_date(s)
      Date.iso8601(s)
    rescue ArgumentError, TypeError
      nil
    end
end