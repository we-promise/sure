class LunchflowItemsController < ProviderItemsController
  private

    def item_params
      params.require(:lunchflow_item).permit(:name, :sync_start_date, :api_key, :base_url)
    end
end
