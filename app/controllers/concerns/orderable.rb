module Orderable
  extend ActiveSupport::Concern

  included do
    before_action :set_order
  end

  private
    def set_order
      @order = AccountOrder.find(params[:order] || Current.user&.default_account_order)
    rescue ArgumentError
      @order = AccountOrder.default
    end
end
