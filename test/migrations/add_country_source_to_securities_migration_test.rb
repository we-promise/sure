# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261121110000_add_country_source_to_securities")

# `up` marks the hints the resolver's offline fallback wrote, and `down`
# removes only the column and its constraint. The schema
# changes roll back with the test's transaction.
class AddCountrySourceToSecuritiesMigrationTest < ActiveSupport::TestCase
  teardown { Security.reset_column_information }

  test "up marks only resolver-fallback rows whose exchange does not confirm the country" do
    rows = {
      no_reason: Security.create!(ticker: "MIG-HINT", exchange_operating_mic: "XNAS", country_code: "GB", offline: true),
      pending: Security.create!(ticker: "MIG-PEND", country_code: "GB", offline: true, offline_reason: "resolution_pending"),
      confirmed: Security.create!(ticker: "MIG-CONFIRMED", exchange_operating_mic: "XNAS", country_code: "US", offline: true),
      online: Security.create!(ticker: "MIG-ONLINE", exchange_operating_mic: "XNAS", country_code: "GB"),
      failed: Security.create!(ticker: "MIG-FAILED", exchange_operating_mic: "XNAS", country_code: "GB",
                               offline: true, offline_reason: "health_check_failed"),
      no_country: Security.create!(ticker: "MIG-NOCOUNTRY", offline: true)
    }

    migrate(:down)
    migrate(:up)

    stored = rows.transform_values { |security| Security.where(id: security.id).pick(:country_source, :region) }
    assert_equal({
      no_reason: [ "user_hint", nil ],
      pending: [ "user_hint", nil ],
      confirmed: [ nil, nil ],
      online: [ nil, "europe" ],
      failed: [ nil, nil ],
      no_country: [ nil, nil ]
    }, stored)
  end

  test "down removes exactly the column and constraint that up adds" do
    columns_up = connection.columns(:securities).map(&:name)
    constraints_up = connection.check_constraints(:securities).map(&:name)

    migrate(:down)
    columns_down = connection.columns(:securities).map(&:name)
    constraints_down = connection.check_constraints(:securities).map(&:name)
    migrate(:up)

    assert_equal [ "country_source" ], columns_up - columns_down
    assert_equal [ AddCountrySourceToSecurities::CONSTRAINT ], constraints_up - constraints_down
    assert_empty columns_down - columns_up
    assert_empty constraints_down - constraints_up
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddCountrySourceToSecurities.new.migrate(direction) }
      Security.reset_column_information
    end
end
