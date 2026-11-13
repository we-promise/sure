class DemoFamilyRefreshMailerPreview < ActionMailer::Preview
  def completed
    DemoFamilyRefreshMailer.with(
      super_admin: User.new(email: "admin@example.com"),
      old_family_id: "00000000-0000-0000-0000-000000000001",
      old_family_name: "Demo Family",
      old_family_session_count: 12,
      newly_created_families_count: 4,
      period_start: Time.utc(2026, 10, 10, 5, 0, 25),
      period_end: Time.utc(2026, 10, 11, 5, 0, 25)
    ).completed
  end
end
