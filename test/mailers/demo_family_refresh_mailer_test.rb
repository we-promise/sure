require "test_helper"

class DemoFamilyRefreshMailerTest < ActionMailer::TestCase
  test "completed email includes the same summary in HTML and plain text" do
    email = completed_email

    assert_equal [ "support@sure.am" ], email.to
    assert_equal "Demo family refresh completed", email.subject
    assert_equal "multipart/alternative", email.mime_type

    [ email.html_part, email.text_part ].each do |part|
      body = part.body.decoded
      assert_includes body, "Unique login sessions for the previous demo family"
      assert_includes body, "1,234"
      assert_includes body, "New family accounts created"
      assert_includes body, "4"
      assert_includes body, "Reporting period (UTC)"
      assert_includes body, "Jan 1, 2026 at 05:00:25 UTC"
      assert_includes body, "Jan 2, 2026 at 05:00:25 UTC"
      assert_includes body, families(:empty).name
      assert_includes body, families(:empty).id
    end
  end

  test "missing previous family and zero activity remain readable in both formats" do
    email = completed_email(old_family_id: nil, old_family_name: nil,
      old_family_session_count: 0, newly_created_families_count: 0)

    [ email.html_part, email.text_part ].each do |part|
      assert_includes part.body.decoded, "Not found"
      assert_not_includes part.body.decoded, "ID:"
    end

    assert_equal 2, Nokogiri::HTML(email.html_part.body.decoded).css("p > strong").count { |node| node.text == "0" }
    assert_includes email.text_part.body.decoded, "Unique login sessions for the previous demo family: 0"
    assert_includes email.text_part.body.decoded, "New family accounts created: 0"
  end

  test "family names are escaped in HTML" do
    email = completed_email(old_family_name: "<script>alert('family')</script>")

    assert_not_includes email.html_part.body.decoded, "<script>"
    assert_includes email.html_part.body.decoded, "&lt;script&gt;"
    assert_includes email.text_part.body.decoded, "<script>"
  end

  private
    def completed_email(**overrides)
      DemoFamilyRefreshMailer.with({
        super_admin: users(:sure_support_staff),
        old_family_id: families(:empty).id,
        old_family_name: families(:empty).name,
        old_family_session_count: 1234,
        newly_created_families_count: 4,
        period_start: Time.new(2025, 12, 31, 21, 0, 25, "-08:00"),
        period_end: Time.new(2026, 1, 1, 21, 0, 25, "-08:00")
      }.merge(overrides)).completed
    end
end
