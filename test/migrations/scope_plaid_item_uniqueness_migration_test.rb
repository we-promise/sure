# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260219200001_scope_plaid_item_uniqueness")

class ScopePlaidItemUniquenessMigrationTest < ActiveSupport::TestCase
  test "defines the legacy migration constant alias" do
    assert_equal ScopePlaidItemUniqueness, ScopePlaidAccountUniquenessToItem
  end
end
