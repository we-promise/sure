# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261121090000_add_constituents_replaced_at_to_securities")

# `down` removes only the column `up` adds. The schema changes roll back with
# the test's transaction.
class AddConstituentsReplacedAtToSecuritiesMigrationTest < ActiveSupport::TestCase
  teardown { Security.reset_column_information }

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
