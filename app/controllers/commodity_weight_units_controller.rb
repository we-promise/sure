# Remembers the user's grams / troy ounces choice for commodity weights.
class CommodityWeightUnitsController < ApplicationController
  def update
    Current.user.update_commodity_weight_unit!(params[:unit].to_s)
    redirect_back_or_to root_path
  end
end
