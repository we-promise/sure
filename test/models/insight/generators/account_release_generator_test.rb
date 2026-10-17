require "test_helper"

class Insight::Generators::AccountReleaseGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family.update!(timezone: "UTC")
    @family.users.update_all(preferences: {}, ai_enabled: false)
    travel_to Time.utc(2026, 10, 5, 12)
  end

  test "reminds the feed of a release within the lead time" do
    enable(@admin, channel: "insight", lead_days: 14)
    account = term_deposit(available_on: Date.new(2026, 10, 15))

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "account_release", insight.insight_type
    assert_equal "medium", insight.priority
    assert_equal({ account_id: account.id, kind: "upcoming", release_on: "2026-10-15" }, insight.metadata)
    assert_equal "account_release:upcoming:#{account.id}:2026-10-15", insight.dedup_key
    assert_equal 10, insight.facts[:days]
  end

  test "a release on the day is high priority" do
    enable(@admin, channel: "both")
    term_deposit(available_on: Date.new(2026, 10, 5))

    insight = generate.first

    assert_equal "high", insight.priority
    assert_equal "released", insight.metadata[:kind]
  end

  test "stays out of the feed when nobody wants reminders there" do
    enable(@admin, channel: "email")
    term_deposit(available_on: Date.new(2026, 10, 6))

    assert_empty generate
  end

  test "ignores members without preview features" do
    @admin.update!(preferences: { "account_release_channel" => "insight" })
    term_deposit(available_on: Date.new(2026, 10, 6))

    assert_empty generate
  end

  test "uses the longest lead time among members who want the feed" do
    enable(@admin, channel: "insight", lead_days: 3)
    enable(@member, channel: "insight", lead_days: 30)
    shared = term_deposit(available_on: Date.new(2026, 10, 25))

    assert_equal [ shared.id ], generate.map { |insight| insight.metadata[:account_id] }
  end

  test "leaves out accounts that count in nobody's finances among the recipients" do
    enable(@member, channel: "insight")
    account = term_deposit(available_on: Date.new(2026, 10, 6))
    AccountShare.find_by!(account: account, user: @member).update!(include_in_finances: false)

    assert_empty generate
  end

  test "leaves out accounts that not every member can see" do
    enable(@admin, channel: "insight")
    term_deposit(available_on: Date.new(2026, 10, 6), private: true)

    assert_empty generate
  end

  test "a renewing deposit is reminded before it renews" do
    enable(@admin, channel: "insight")
    term_deposit(available_on: Date.new(2026, 10, 13), auto_renew: true, renewal_term_months: 12)

    insight = generate.first

    assert_equal "renewal", insight.metadata[:kind]
    assert_equal "account_release.renewal_notice", insight.template_key
    assert_equal I18n.l(Date.new(2026, 10, 13), format: :long), insight.facts[:date]
  end

  test "a renewal outside the lead time is not reminded" do
    enable(@admin, channel: "insight")
    term_deposit(available_on: Date.new(2026, 12, 8), auto_renew: true, renewal_term_months: 12)

    assert_empty generate
  end

  test "writes the reminder in German" do
    enable(@admin, channel: "insight")
    term_deposit(available_on: Date.new(2026, 10, 15), name: "Festgeld")

    generated = I18n.with_locale(:de) { generate.first }
    body = I18n.with_locale(:de) { Insight::BodyWriter.new(@family).write(generated) }

    assert_equal "Festgeld wird bald frei", generated.title
    assert_equal "#{generated.facts[:balance]} auf Festgeld werden am 15. Oktober 2026 verfügbar.", body
  end

  private
    def generate
      Insight::Generators::AccountReleaseGenerator.new(@family).generate
    end

    def enable(user, channel:, lead_days: 14)
      user.update!(preferences: {
        "preview_features_enabled" => true,
        "account_release_channel" => channel,
        "account_release_lead_days" => lead_days
      })
    end

    # Shared with the other member unless private, so the whole family sees it
    # like the feed does.
    def term_deposit(available_on:, name: "Term deposit", private: false, **attributes)
      account = @family.accounts.create!(name: name, balance: 5000, currency: "USD", owner: @admin,
                                         accountable: Depository.new(subtype: "cd"), available_on: available_on, **attributes)
      AccountShare.find_or_create_by!(account: account, user: @member) { |share| share.permission = "read_only" } unless private
      account
    end
end
