# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261121090000_add_constituents_replaced_at_to_securities")

# `up` dates a replacement only for a fund holding a stored set, and `down`
# removes only the column. The schema changes roll back with the test's
# transaction.
class AddConstituentsReplacedAtToSecuritiesMigrationTest < ActiveSupport::TestCase
  teardown { Security.reset_column_information }

  test "up dates the replacement of a stored set only" do
    stamped_at = 1.day.ago.floor(6)
    held = Security.create!(ticker: "MIG-HELD")
    held.constituents.create!(ticker: "AAA", weight: 100)
    empty = Security.create!(ticker: "MIG-EMPTY")
    never = Security.create!(ticker: "MIG-NEVER")
    [ held, empty ].each { |security| security.update_columns(constituents_fetched_at: stamped_at) }

    migrate(:down)
    migrate(:up)

    replaced = [ held, empty, never ].map { |security| Security.where(id: security.id).pick(:constituents_replaced_at) }
    assert_equal [ stamped_at, nil, nil ], replaced
  end

  test "down removes only the column up adds" do
    columns_up = connection.columns(:securities).map(&:name)
    migrate(:down)
    columns_down = connection.columns(:securities).map(&:name)
    migrate(:up)

    assert_equal [ "constituents_replaced_at" ], columns_up - columns_down
    assert_empty columns_down - columns_up
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddConstituentsReplacedAtToSecurities.new.migrate(direction) }
      Security.reset_column_information
    end
end
