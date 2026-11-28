# frozen_string_literal: true

require "test_helper"

class BrexItemsProviderKitTest < ActionDispatch::IntegrationTest
  include ProviderItemsControllerTests

  private
    def provider_item
      @provider_item ||= brex_items(:one)
    end
end
