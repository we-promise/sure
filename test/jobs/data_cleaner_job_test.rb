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

  test "deletes bill suggestions older than a week and keeps recent ones" do
    family = families(:dylan_family)
    create_series = ->(name:) do
      family.recurring_transactions.create!(
        name:, account: accounts(:depository), amount: 40, currency: "USD",
        expected_day_of_month: 9, anchor_date: Date.current, last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current, status: "active", manual: true
      )
    end
    old_series = create_series.call(name: "Old gym")
    recent_series = create_series.call(name: "Recent gym")
    old = family.recurring_transaction_suggestions.create!(user: users(:family_admin), recurring_transaction: old_series,
                                                           mode: :configure, created_at: 8.days.ago)
    recent = family.recurring_transaction_suggestions.create!(user: users(:family_admin), recurring_transaction: recent_series,
                                                              mode: :configure)

    DataCleanerJob.perform_now

    assert_not RecurringTransaction::Suggestion.exists?(old.id)
    assert RecurringTransaction::Suggestion.exists?(recent.id)
  end
end
