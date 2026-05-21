# frozen_string_literal: true

require "test_helper"

class DataCleanerJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "clears stale Enable Banking PSU IP addresses" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      stale_item = EnableBankingItem.create!(
        family: @family,
        name: "Stale EB",
        country_code: "FR",
        application_id: "app_id",
        client_certificate: "cert",
        last_psu_ip: "203.0.113.10",
        last_psu_ip_at: 1.day.ago,
        session_id: "sess",
        session_expires_at: 1.hour.ago
      )
      fresh_item = EnableBankingItem.create!(
        family: @family,
        name: "Fresh EB",
        country_code: "FR",
        application_id: "app_id",
        client_certificate: "cert",
        last_psu_ip: "203.0.113.11",
        last_psu_ip_at: 1.day.ago,
        session_id: "sess",
        session_expires_at: 30.days.from_now
      )

      DataCleanerJob.perform_now

      stale_item.reload
      fresh_item.reload

      assert_nil stale_item.last_psu_ip
      assert_nil stale_item.last_psu_ip_at
      assert_equal "203.0.113.11", fresh_item.last_psu_ip
      assert_equal 1.day.ago, fresh_item.last_psu_ip_at
    end
  end
end
