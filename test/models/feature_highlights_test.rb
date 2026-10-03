require "test_helper"

class FeatureHighlightsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
  end

  test "bills is pending for a preview user on a release that carries it" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: { "preview_features_enabled" => true })

    pending = FeatureHighlights.pending_for(@user)

    assert_equal "bills", pending.key
    assert_equal "v0.7.5-alpha.1", pending.min_tag
  end

  test "bills is pending on a 0.7.5 alpha, so it can be exercised before the final tag" do
    Sure.stubs(:version).returns(Semver.new("0.7.5-alpha.8"))
    @user.update!(preferences: { "preview_features_enabled" => true })

    assert_equal "bills", FeatureHighlights.pending_for(@user).key
  end

  test "nothing pending for a user without preview features, even on a release that carries the feature" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))

    assert_nil FeatureHighlights.pending_for(@user)
  end

  test "nothing pending on a release older than the feature's min tag" do
    Sure.stubs(:version).returns(Semver.new("0.7.4"))
    @user.update!(preferences: { "preview_features_enabled" => true })

    assert_nil FeatureHighlights.pending_for(@user)
  end

  test "nothing pending for a family with recurring transactions disabled" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: { "preview_features_enabled" => true })
    @user.family.update!(recurring_transactions_disabled: true)

    assert_nil FeatureHighlights.pending_for(@user)
  end

  test "nothing pending once the feature's min tag was seen" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: { "preview_features_enabled" => true })
    @user.mark_feature_highlight_seen!("bills", "v0.7.5-alpha.1")

    assert_nil FeatureHighlights.pending_for(@user)
  end

  # This is what re-highlighting a revamped feature looks like: the registry
  # min_tag moves past the stored tag, so a stale seen marker is no longer
  # enough and the feature is offered again.
  test "pending again when the seen tag is older than the registry min tag" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: { "preview_features_enabled" => true })
    @user.mark_feature_highlight_seen!("bills", "v0.0.1")

    assert_equal "bills", FeatureHighlights.pending_for(@user).key
  end

  test "a malformed stored tag counts as unseen so the account recovers" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: {
      "preview_features_enabled" => true,
      "seen_feature_highlights" => { "bills" => "not-a-release" }
    })

    assert_equal "bills", FeatureHighlights.pending_for(@user).key
  end

  test "nothing pending without a user" do
    assert_nil FeatureHighlights.pending_for(nil)
  end

  test "unparseable local version yields nothing pending" do
    Sure.stubs(:version).raises(ArgumentError)
    @user.update!(preferences: { "preview_features_enabled" => true })

    assert_nil FeatureHighlights.pending_for(@user)
  end

  test "mark_feature_highlight_seen! stores the tag under the feature key" do
    @user.mark_feature_highlight_seen!("bills", "v0.7.5-alpha.1")

    assert_equal "v0.7.5-alpha.1", @user.reload.seen_feature_highlights["bills"]
  end

  test "mark_feature_highlight_seen! never regresses a feature's tag" do
    @user.mark_feature_highlight_seen!("bills", "v0.7.5")
    @user.mark_feature_highlight_seen!("bills", "v0.7.4")

    assert_equal "v0.7.5", @user.reload.seen_feature_highlights["bills"]
  end

  test "mark_feature_highlight_seen! accepts a newer tag" do
    @user.mark_feature_highlight_seen!("bills", "v0.7.4")
    @user.mark_feature_highlight_seen!("bills", "v0.7.5")

    assert_equal "v0.7.5", @user.reload.seen_feature_highlights["bills"]
  end

  test "mark_feature_highlight_seen! rejects malformed tags" do
    assert_raises(ArgumentError) do
      @user.mark_feature_highlight_seen!("bills", "not-a-release")
    end

    assert_empty @user.reload.seen_feature_highlights
  end

  test "mark_feature_highlight_seen! recovers from a previously stored malformed tag" do
    @user.update!(preferences: { "seen_feature_highlights" => { "bills" => "not-a-release" } })

    @user.mark_feature_highlight_seen!("bills", "v0.7.5")

    assert_equal "v0.7.5", @user.reload.seen_feature_highlights["bills"]
  end

  test "mark_feature_highlight_seen! tracks features independently" do
    @user.mark_feature_highlight_seen!("bills", "v0.7.5")
    @user.mark_feature_highlight_seen!("plan", "v0.7.4")

    assert_equal "v0.7.5", @user.reload.seen_feature_highlights["bills"]
    assert_equal "v0.7.4", @user.reload.seen_feature_highlights["plan"]
  end
end
