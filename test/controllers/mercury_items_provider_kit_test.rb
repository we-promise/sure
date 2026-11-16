# frozen_string_literal: true

require "test_helper"

class MercuryItemsProviderKitTest < ActionDispatch::IntegrationTest
  include ProviderItemsControllerTests

  private
    def provider_item
      @provider_item ||= mercury_items(:one)
    end
end
