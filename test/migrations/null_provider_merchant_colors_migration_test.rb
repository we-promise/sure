# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260925220151_null_provider_merchant_colors")

class NullProviderMerchantColorsMigrationTest < ActiveSupport::TestCase
  setup do
    @provider_merchant = ProviderMerchant.create!(name: "Legacy", source: "plaid")
    @provider_merchant.update_column(:color, "#654321")
    @family_merchant = families(:dylan_family).merchants.create!(name: "Mine", color: "#4da568")
  end

  test "clears the color stored on provider merchants" do
    run_migration

    assert_nil ProviderMerchant.where(id: @provider_merchant.id).pick(:color)
  end

  test "leaves family merchants and everything else on the row alone" do
    run_migration

    assert_equal "#4da568", @family_merchant.reload.color
    assert_equal "Legacy", ProviderMerchant.find(@provider_merchant.id).name
  end

  test "can be run again" do
    2.times { run_migration }

    assert_nil ProviderMerchant.where(id: @provider_merchant.id).pick(:color)
  end

  private

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        NullProviderMerchantColors.new.up
      end
    end
end
