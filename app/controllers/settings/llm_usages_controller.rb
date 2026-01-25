class Settings::LlmUsagesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.llm_usages"), nil ]
    ]
  end



  private
    def safe_parse_date(s)
      Date.iso8601(s)
    rescue ArgumentError, TypeError
      nil
    end
end
