class Settings::PaymentsController < ApplicationController
  layout "settings"

  def show
    @family = Current.family
  end
end
