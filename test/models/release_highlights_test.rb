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

  test "unparseable local version yields no pending tag" do
    Sure.stubs(:version).raises(ArgumentError)

    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "every release is eligible while the rollout is being tested" do
    assert ReleaseHighlights.eligible?(Semver.new("0.7.5-alpha.7"))
    assert ReleaseHighlights.eligible?(Semver.new("0.7.4"))
  end
end
