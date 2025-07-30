module Orderable
  extend ActiveSupport::Concern

  included do
    before_action :set_order
  end

  private
    def set_order
      @order = MenuOrder.find(params[:order] || Current.user&.default_order)
    rescue ArgumentError
      @order = MenuOrder.default
    end
end
