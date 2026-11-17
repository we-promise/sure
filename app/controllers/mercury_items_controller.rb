class MercuryItemsController < ProviderItemsController
  private

    def item_params
      permitted = params.require(:mercury_item).permit(:name, :sync_start_date, :token, :base_url)
      permitted.delete(:token) if @mercury_item&.persisted? && permitted[:token].blank?
      permitted
    end
end
