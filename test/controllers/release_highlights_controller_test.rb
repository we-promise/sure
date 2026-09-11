require "test_helper"

class ReleaseHighlightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: {})
  end

  test "show renders the pending release notes" do
    release_notes = {
      avatar: nil,
      username: "we-promise",
      name: Sure.version.to_release_tag,
      published_at: Date.current,
      body: "<p>Shiny new things</p>"
    }
    github_provider = mock
    github_provider.expects(:fetch_release_notes).with(Sure.version.to_release_tag).returns(release_notes)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get release_highlight_path

    assert_response :ok
    assert_select "h2", text: Sure.version.to_release_tag
    assert_select "p", text: "Shiny new things"
  end

  test "show returns no content once the deployed release was seen" do
    @user.mark_release_seen!(Sure.version.to_release_tag)

    github_provider = mock
    github_provider.expects(:fetch_release_notes).never
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get release_highlight_path

    assert_response :no_content
  end

  test "show returns no content when release notes are unavailable" do
    github_provider = mock
    github_provider.expects(:fetch_release_notes).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get release_highlight_path

    assert_response :no_content
  end

  test "dismiss marks the pending release as seen" do
    patch release_highlight_dismiss_path, as: :json

    assert_response :ok
    assert_equal Sure.version.to_release_tag, @user.reload.last_seen_release_tag
  end

  test "dismiss ignores a client-supplied tag and binds to the pending release" do
    patch release_highlight_dismiss_path, params: { tag: "v9.9.9" }, as: :json

    assert_response :ok
    assert_equal Sure.version.to_release_tag, @user.reload.last_seen_release_tag
  end

  test "dismiss returns no content when no release is pending" do
    @user.mark_release_seen!(Sure.version.to_release_tag)

    patch release_highlight_dismiss_path, as: :json

    assert_response :no_content
  end

  test "dismiss_feature marks the pending feature as seen" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: { "preview_features_enabled" => true })

    patch feature_highlight_dismiss_path(key: "bills"), as: :json

    assert_response :ok
    assert_equal "v0.7.5-alpha.1", @user.reload.seen_feature_highlights["bills"]
  end

  test "dismiss_feature rejects keys that are not pending" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))
    @user.update!(preferences: { "preview_features_enabled" => true })

    patch feature_highlight_dismiss_path(key: "plan"), as: :json

    assert_response :unprocessable_entity
    assert_empty @user.reload.seen_feature_highlights
  end

  test "dismiss_feature rejects the feature when the user is not eligible" do
    Sure.stubs(:version).returns(Semver.new("0.7.5"))

    patch feature_highlight_dismiss_path(key: "bills"), as: :json

    assert_response :unprocessable_entity
    assert_empty @user.reload.seen_feature_highlights
  end
end
