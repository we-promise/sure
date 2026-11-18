module InsightTestHelper
  # The digest Insight::Generator stores on a total, computed the way it was
  # first written in Ruby, so tests check the SQL against an independent oracle.
  def ruby_shared_accounts_digest(family)
    Digest::SHA256.hexdigest(family.accounts.accessible_by_all_active_members.order(:id).pluck(:id).join(","))
  end

  # A household total computed from the accounts every member can open now.
  def household_total(family, status: "active", dedup_key: "savings_rate_change:current")
    family.insights.create!(
      insight_type: "savings_rate_change", priority: "medium", status: status, title: "Savings", body: "body",
      metadata: { "current_rate" => 40.0, "accounts_digest" => ruby_shared_accounts_digest(family) },
      dedup_key: dedup_key, generated_at: Time.current
    )
  end
end
