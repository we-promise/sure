# frozen_string_literal: true

require "test_helper"

class RevolutXItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemModelLifecycleTests

  private
    def provider_item
      @provider_item ||= revolut_x_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= mercury_accounts(:checking_account)
    end
end
