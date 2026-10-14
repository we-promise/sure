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

  test "dismissing a hotfix preserves the legacy base release acknowledgement" do
    @user.update!(preferences: { "last_seen_release_tag" => "v0.7.5", "custom_preference" => true })
    Sure.stubs(:version).returns(Semver.new("0.7.5-hotfix.1"))

    assert_equal "v0.7.5-hotfix.1", ReleaseHighlights.pending_tag_for(@user)
    @user.mark_release_seen!("v0.7.5-hotfix.1")
    assert_nil ReleaseHighlights.pending_tag_for(@user.reload)
    assert @user.preferences["custom_preference"]

    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "legacy acknowledgement suppresses the popup before any new dismissal" do
    @user.update!(preferences: { "last_seen_release_tag" => Sure.version.to_release_tag })

    assert_nil ReleaseHighlights.pending_tag_for(@user.reload)
  end

  test "stale instances merge acknowledgements across release channels without duplicates" do
    stale_user = User.find(@user.id)
    @user.mark_release_seen!("v0.7.6-alpha.1")
    stale_user.mark_release_seen!("v0.7.5-hotfix.1")
    @user.mark_release_seen!("v0.7.6-alpha.1")

    @user.reload
    [ "0.7.6-alpha.1", "0.7.5-hotfix.1" ].each do |version|
      Sure.stubs(:version).returns(Semver.new(version))
      assert_nil ReleaseHighlights.pending_tag_for(@user)
    end
    assert_equal 2, @user.preferences.fetch("seen_release_tags").size

    Sure.stubs(:version).returns(Semver.new("0.7.6"))
    assert_equal "v0.7.6", ReleaseHighlights.pending_tag_for(@user)
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
