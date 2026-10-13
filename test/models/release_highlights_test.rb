require "test_helper"

class ReleaseHighlightsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
  end

  test "pending tag when the deployed release is unseen" do
    assert_equal Sure.version.to_release_tag, ReleaseHighlights.pending_tag_for(@user)
  end

  test "no pending tag once the deployed release was seen" do
    @user.mark_release_seen!(Sure.version.to_release_tag)

    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "pending tag returns when only a different release was seen" do
    @user.mark_release_seen!("v0.0.0-some-older-release")

    assert_equal Sure.version.to_release_tag, ReleaseHighlights.pending_tag_for(@user)
  end

  test "no pending tag without a user" do
    assert_nil ReleaseHighlights.pending_tag_for(nil)
  end

  test "no pending tag when the user already saw a newer release than the currently deployed one" do
    # Simulates a rolling deploy/rollback: the user's browser already marked
    # a release newer than what this app instance is running right now.
    @user.mark_release_seen!("v999.0.0")

    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "unparseable local version yields no pending tag" do
    Sure.stubs(:version).raises(ArgumentError)

    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "mark_release_seen! never regresses to an older tag" do
    @user.mark_release_seen!("v0.7.5-alpha.7")
    @user.mark_release_seen!("v0.7.4")

    assert_equal "v0.7.5-alpha.7", @user.reload.last_seen_release_tag
  end

  test "mark_release_seen! accepts a newer tag" do
    @user.mark_release_seen!("v0.7.4")
    @user.mark_release_seen!("v0.7.5-alpha.7")

    assert_equal "v0.7.5-alpha.7", @user.reload.last_seen_release_tag
  end

  test "mark_release_seen! rejects malformed tags" do
    assert_raises(ArgumentError) do
      @user.mark_release_seen!("not-a-release")
    end

    assert_nil @user.reload.last_seen_release_tag
  end

  test "mark_release_seen! recovers from a previously stored malformed tag" do
    @user.update!(preferences: { "last_seen_release_tag" => "not-a-release" })

    @user.mark_release_seen!("v0.7.5-alpha.7")

    assert_equal "v0.7.5-alpha.7", @user.reload.last_seen_release_tag
  end

  test "every release is eligible while the rollout is being tested" do
    assert ReleaseHighlights.eligible?(Semver.new("0.7.5-alpha.7"))
    assert ReleaseHighlights.eligible?(Semver.new("0.7.4"))
  end
end
