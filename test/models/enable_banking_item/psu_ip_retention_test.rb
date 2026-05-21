# frozen_string_literal: true

require "test_helper"

class EnableBankingItem::PsuIpRetentionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @base_attrs = {
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "app_id",
      client_certificate: "cert"
    }
  end

  test "with_stale_psu_ip includes items with expired session" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      item = create_item(
        last_psu_ip: "203.0.113.1",
        last_psu_ip_at: 1.day.ago,
        session_id: "sess",
        session_expires_at: 1.hour.ago
      )

      assert_includes EnableBankingItem.with_stale_psu_ip, item
    end
  end

  test "with_stale_psu_ip includes items with IP older than retention period" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      item = create_item(
        last_psu_ip: "203.0.113.2",
        last_psu_ip_at: 91.days.ago,
        session_id: "sess",
        session_expires_at: 30.days.from_now
      )

      assert_includes EnableBankingItem.with_stale_psu_ip, item
    end
  end

  test "with_stale_psu_ip includes legacy items without last_psu_ip_at past retention" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      item = EnableBankingItem.create!(@base_attrs.merge(
        last_psu_ip: "203.0.113.3",
        session_id: "sess",
        session_expires_at: 30.days.from_now
      ))
      item.update_columns(updated_at: 91.days.ago, last_psu_ip_at: nil)

      assert_includes EnableBankingItem.with_stale_psu_ip, item
    end
  end

  test "with_stale_psu_ip excludes fresh IP with valid session" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      item = create_item(
        last_psu_ip: "203.0.113.4",
        last_psu_ip_at: 10.days.ago,
        session_id: "sess",
        session_expires_at: 30.days.from_now
      )

      assert_not_includes EnableBankingItem.with_stale_psu_ip, item
    end
  end

  test "clear_stale_psu_ip! nullifies IP fields" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      item = create_item(
        last_psu_ip: "203.0.113.5",
        last_psu_ip_at: 1.day.ago,
        session_id: "sess",
        session_expires_at: 1.hour.ago
      )

      EnableBankingItem.clear_stale_psu_ip!
      item.reload

      assert_nil item.last_psu_ip
      assert_nil item.last_psu_ip_at
    end
  end

  test "record_psu_ip! sets IP and timestamp" do
    travel_to Time.zone.parse("2026-05-20 12:00:00") do
      item = EnableBankingItem.create!(@base_attrs)

      item.record_psu_ip!("198.51.100.1")
      item.reload

      assert_equal "198.51.100.1", item.last_psu_ip
      assert_equal Time.current, item.last_psu_ip_at
    end
  end

  test "record_psu_ip! ignores blank IP" do
    item = EnableBankingItem.create!(@base_attrs)

    item.record_psu_ip!("")
    item.reload

    assert_nil item.last_psu_ip
    assert_nil item.last_psu_ip_at
  end

  private

    def create_item(**attrs)
      EnableBankingItem.create!(@base_attrs.merge(attrs))
    end
end
