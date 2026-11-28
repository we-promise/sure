class LunchflowItemsController < ProviderItemsController
  private

    def item_params
      permitted = params.require(:lunchflow_item).permit(:name, :sync_start_date, :api_key, :base_url)
      permitted.delete(:api_key) if @lunchflow_item&.persisted? && permitted[:api_key].blank?
      permitted
    end
end
