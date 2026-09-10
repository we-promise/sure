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

  test "dismiss marks the given tag as seen" do
    patch release_highlight_dismiss_path, params: { tag: "v1.2.3" }, as: :json

    assert_response :ok
    assert_equal "v1.2.3", @user.reload.last_seen_release_tag
  end

  test "dismiss without a tag marks the deployed release as seen" do
    patch release_highlight_dismiss_path, as: :json

    assert_response :ok
    assert_equal Sure.version.to_release_tag, @user.reload.last_seen_release_tag
  end
end
