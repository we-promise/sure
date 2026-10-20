require "test_helper"

class InsightTest < ActiveSupport::TestCase
  setup do
    @insight = insights(:spending_anomaly_dining)
  end

  test "mark_read! transitions active insight and stamps read_at" do
    assert @insight.active?

    @insight.mark_read!

    assert @insight.reload.read?
    assert @insight.read_at.present?
  end

  test "mark_read! does not touch acknowledged insights" do
    @insight.acknowledge!

    @insight.mark_read!

    assert @insight.reload.acknowledged?
    assert_nil @insight.read_at
  end

  test "acknowledge! removes insight from visible scope" do
    assert_includes Insight.visible, @insight

    @insight.acknowledge!

    assert_not_includes Insight.visible, @insight
    assert @insight.dismissed_at.present?
  end

  test "unacknowledge! restores an acknowledged insight as read, not new" do
    @insight.acknowledge!

    @insight.unacknowledge!

    assert @insight.reload.read?
    assert_nil @insight.dismissed_at
    assert @insight.read_at.present?
    assert_includes Insight.visible, @insight
  end

  # A stale/replayed undo (e.g. an old toast link clicked after the insight
  # has since expired or resurrected) must not force a non-acknowledged
  # insight back to :read — that would wrongly pull an :expired insight back
  # into view.
  test "unacknowledge! is a no-op on an insight that isn't acknowledged" do
    @insight.update!(status: :expired)

    @insight.unacknowledge!

    assert @insight.reload.expired?
  end

  test "duplicate dedup_key within a family is rejected" do
    assert_raises ActiveRecord::RecordInvalid do
      @insight.family.insights.create!(
        insight_type: @insight.insight_type,
        priority: "medium",
        title: "Duplicate",
        body: "Duplicate body",
        dedup_key: @insight.dedup_key
      )
    end
  end

  test "same dedup_key is allowed across families" do
    other_family = families(:empty)

    assert_nothing_raised do
      other_family.insights.create!(
        insight_type: @insight.insight_type,
        priority: "medium",
        title: "Same key, other family",
        body: "Body",
        dedup_key: @insight.dedup_key
      )
    end
  end

  test "ordered puts high priority first, then most recent" do
    high = insights(:cash_flow_warning)

    assert_equal high, Insight.ordered.first
  end

  test "insight_type must be a known type" do
    insight = Insight.new(
      family: families(:empty),
      insight_type: "bogus",
      title: "t",
      body: "b",
      dedup_key: "bogus:key"
    )

    assert_not insight.valid?
    assert insight.errors[:insight_type].any?
  end

  test "visible hides an insight about an account a member cannot see" do
    family = families(:dylan_family)
    shared = idle_cash_insight(family, accounts(:depository))
    private_one = idle_cash_insight(family, accounts(:connected))
    gone = idle_cash_insight(family, Struct.new(:id).new(SecureRandom.uuid))

    visible = family.insights.visible

    assert_includes visible, shared
    assert_not_includes visible, private_one
    assert_not_includes visible, gone, "an insight about a deleted account is hidden too"
    assert_includes visible, @insight, "insights without an account are untouched"
    assert private_one.reload.active?, "hiding writes nothing; the row returns as it was"
  end

  test "revoking a share hides an insight about that account right away" do
    family = families(:dylan_family)
    insight = idle_cash_insight(family, accounts(:depository))

    accounts(:depository).unshare_with!(users(:family_member))

    assert_not_includes family.insights.visible, insight
  end

  test "a member joining without access hides an insight about the account" do
    family = families(:dylan_family)
    insight = idle_cash_insight(family, accounts(:depository))

    family.users.create!(email: "newcomer@example.com", password: "password123!A", first_name: "New", last_name: "Member", role: "member")

    assert_not_includes family.insights.visible, insight
  end

  test "an inactive member does not hide an insight" do
    family = families(:dylan_family)
    insight = idle_cash_insight(family, accounts(:connected))

    users(:family_member).update_columns(active: false)

    assert_includes family.insights.visible, insight
  end

  test "an insight about another family's account id is hidden" do
    family = families(:dylan_family)
    insight = idle_cash_insight(family, accounts(:connected))
    insight.update_columns(family_id: families(:empty).id)

    assert_not_includes families(:empty).insights.visible, insight
  end

  test "a malformed account id hides the insight instead of raising" do
    family = families(:dylan_family)
    insight = idle_cash_insight(family, Struct.new(:id).new("not-a-uuid"))

    assert_not_includes family.insights.visible.to_a, insight
  end

  test "an insight about an account pending deletion is hidden" do
    family = families(:dylan_family)
    insight = idle_cash_insight(family, accounts(:depository))

    accounts(:depository).update_columns(status: "pending_deletion")

    assert_not_includes family.insights.visible, insight
  end

  private
    def idle_cash_insight(family, account)
      family.insights.create!(
        insight_type: "idle_cash", priority: "low", status: "active", title: "Idle", body: "body",
        metadata: { "account_id" => account.id }, dedup_key: "idle_cash:#{account.id}",
        generated_at: Time.current
      )
    end
end
