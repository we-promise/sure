class CommodityLocationsController < ApplicationController
  def index
    @locations = Current.family.commodity_locations.alphabetically
    @item_counts = Commodity::Item.where(location: @locations).group(:location_id).count
  end

  def create
    location = Current.family.commodity_locations.build(location_params)

    if location.save
      redirect_to commodity_locations_path, notice: t(".success")
    else
      redirect_to commodity_locations_path, alert: location.errors.full_messages.to_sentence
    end
  end

  def update
    location = Current.family.commodity_locations.find(params[:id])

    if location.update(location_params)
      redirect_to commodity_locations_path, notice: t(".success")
    else
      redirect_to commodity_locations_path, alert: location.errors.full_messages.to_sentence
    end
  end

  # Items keep their history; their current location becomes unassigned.
  def destroy
    Current.family.commodity_locations.find(params[:id]).destroy!
    redirect_to commodity_locations_path, notice: t(".success")
  end

  private
    def location_params
      params.require(:commodity_location).permit(:name)
    end
end
