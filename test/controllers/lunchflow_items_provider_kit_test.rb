# frozen_string_literal: true

require "test_helper"

class LunchflowItemsProviderKitTest < ActionDispatch::IntegrationTest
  include ProviderItemsControllerTests

  private
    def provider_item
      @provider_item ||= lunchflow_items(:one)
    end
end
