class Transactions::MerchantFiltersController < ApplicationController
  def show
    @selected = Array(params[:merchants])
    @merchants = [ Merchant.no_merchant ] + Current.family.assigned_merchants_for(Current.user).with_attached_logo.alphabetically
  end
end
