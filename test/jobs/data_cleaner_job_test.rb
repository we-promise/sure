require "test_helper"

class DataCleanerJobTest < ActiveSupport::TestCase
  test "clears last_psu_ip on Enable Banking items with an expired session" do
    expired = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Expired", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.ago
    )

    DataCleanerJob.perform_now

    assert_nil expired.reload.last_psu_ip
  end

  test "keeps last_psu_ip on Enable Banking items with a valid session" do
    active = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Active", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.from_now
    )

    DataCleanerJob.perform_now

    assert_equal "1.2.3.4", active.reload.last_psu_ip
  end
end
