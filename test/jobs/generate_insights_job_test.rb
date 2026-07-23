require "test_helper"

class GenerateInsightsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "without args enqueues one job per family" do
    assert_enqueued_jobs Family.count, only: GenerateInsightsJob do
      GenerateInsightsJob.perform_now
    end
  end

  test "does nothing for an unknown family" do
    assert_nothing_raised do
      GenerateInsightsJob.perform_now(family_id: SecureRandom.uuid)
    end
  end

  test "does nothing for a family without accounts" do
    family = families(:empty)

    assert_no_difference "Insight.count" do
      GenerateInsightsJob.perform_now(family_id: family.id)
    end
  end

  test "runs all generators against real family data without raising" do
    assert_nothing_raised do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
  end

  test "creates an active insight rendering a live template body from a generated insight" do
    stub_generated([ generated_insight ])

    assert_difference "@family.insights.count", 1 do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    assert_equal "active", insight.status
    assert_equal "idle_cash", insight.insight_type
    assert_equal "idle_cash", insight.template_key
    # No LLM is configured in tests, so no body is stored; the card renders
    # the i18n template live in the viewer's locale.
    assert_nil insight.body
    assert insight.display_body.present?
    assert_equal 5000.0, insight.metadata["balance"]
  end

  test "re-running with unchanged numbers does not duplicate or rewrite" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    Insight::BodyWriter.any_instance.expects(:write).never
    assert_no_difference "@family.insights.count" do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
  end

  test "persists display facts and refreshes them without a prose rewrite when metadata is unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    assert_equal({ "amount" => 5000.0, "currency" => "USD" }, insight.facts["balance"])
    insight.mark_read!

    stub_generated([ generated_insight(display_balance: 5040) ])
    Insight::BodyWriter.any_instance.expects(:write).never
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert_equal({ "amount" => 5040.0, "currency" => "USD" }, insight.facts["balance"])
    assert insight.read?
  end

  test "refreshes prose of rows predating template_key without undoing read state" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.mark_read!
    # A row written before template_key existed: prose snapshotted under
    # whatever locale and translations generation ran with at the time.
    insight.update!(template_key: nil, title: "Stale title", body: "Stale body")

    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert_equal "idle_cash", insight.template_key
    assert_equal "Idle cash in Test Checking", insight.title
    assert_nil insight.body
    assert insight.read?
  end

  test "broadcasts the refreshed feed rendered in the family's locale" do
    @family.update!(locale: "fr")
    stub_generated([ generated_insight ])

    seen_locales = []
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with do
      seen_locales << I18n.locale
      true
    end

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert_equal [ :fr, :fr ], seen_locales
  end

  test "dismissed insight stays dismissed when numbers are unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.dismiss!

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.dismissed?
  end

  test "dismissed insight reactivates when numbers change materially" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.dismiss!

    stub_generated([ generated_insight(balance: 9000.0) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert insight.active?
    assert_equal 9000.0, insight.metadata["balance"]
    assert_nil insight.dismissed_at
    assert_nil insight.read_at
  end

  test "expires a visible insight whose condition cleared" do
    insight = insights(:cash_flow_warning)
    stub_generated([], succeeded_types: [ "cash_flow_warning" ])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.expired?
    assert_not_includes Insight.visible, insight
  end

  test "does not expire insights whose generator failed" do
    insight = insights(:cash_flow_warning)
    stub_generated([], succeeded_types: [])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.active?
  end

  test "does not touch dismissed insights when their condition clears" do
    insight = insights(:cash_flow_warning)
    insight.dismiss!
    stub_generated([], succeeded_types: [ "cash_flow_warning" ])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.dismissed?
  end

  test "expired insight reactivates without a prose rewrite when the condition returns unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.mark_read!

    stub_generated([], succeeded_types: [ "idle_cash" ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    assert insight.reload.expired?

    stub_generated([ generated_insight ])
    Insight::BodyWriter.any_instance.expects(:write).never
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert insight.active?
    assert_nil insight.read_at
  end

  private
    def stub_generated(generated_insights, succeeded_types: nil)
      result = Insight::GeneratorRegistry::Result.new(
        insights: generated_insights,
        succeeded_types: succeeded_types || generated_insights.map(&:insight_type).uniq
      )
      Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(result)
    end

    # display_balance changes only the formatted facts, leaving metadata (the
    # material-change signal) untouched — mirrors a balance drifting slightly
    # between runs without crossing a bucket boundary.
    def generated_insight(balance: 5000.0, display_balance: nil)
      Insight::Generator::GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: "low",
        title: "Idle cash in Test Checking",
        template_key: "idle_cash",
        facts: { account: "Test Checking", balance: { amount: (display_balance || balance).to_f, currency: "USD" }, idle_days: 60 },
        metadata: { account_id: "test-account", balance: balance },
        currency: "USD",
        period_start: nil,
        period_end: nil,
        dedup_key: "idle_cash:test-account:2026-07"
      )
    end
end
