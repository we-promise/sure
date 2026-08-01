class SecuritiesController < ApplicationController
  require_module! :investments

  def index
    @securities = Security.search_provider(
      params[:q],
      country_code: params[:country_code].presence
    )
  end
end
