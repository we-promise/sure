require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "dashboard" do
    get root_path
    assert_response :ok
  end

  test "dashboard cashflow uses default period from user preferences" do
    # Update user's default period to last_7_days
    @user.update!(default_period: "last_7_days")

    get root_path
    assert_response :ok

    # Verify that cashflow period is set to user's default period
    assert_equal "last_7_days", assigns(:cashflow_period).key
  end

  test "dashboard cashflow respects explicit cashflow_period param" do
    # Update user's default period to last_7_days
    @user.update!(default_period: "last_7_days")

    # Pass an explicit cashflow_period param
    get root_path, params: { cashflow_period: "last_90_days" }
    assert_response :ok

    # Verify that cashflow period uses the explicit param, not the default
    assert_equal "last_90_days", assigns(:cashflow_period).key
  end

  test "dashboard cashflow falls back to last_30_days if user has no default_period" do
    # Ensure user has no default period set (should use default value)
    @user.update!(default_period: "last_30_days")

    get root_path
    assert_response :ok

    # Verify that cashflow period falls back to last_30_days
    assert_equal "last_30_days", assigns(:cashflow_period).key
  end

  test "changelog" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
    end
  end

  test "changelog with nil release notes" do
    # Mock the GitHub provider to return nil (simulating API failure or no releases)
    github_provider = mock
    github_provider.expects(:fetch_latest_release_notes).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Release notes unavailable"
    assert_select "a[href='https://github.com/we-promise/sure/releases']"
  end

  test "changelog with incomplete release notes" do
    # Mock the GitHub provider to return incomplete data (missing some fields)
    github_provider = mock
    incomplete_data = {
      avatar: nil,
      username: "maybe-finance",
      name: "Test Release",
      published_at: nil,
      body: nil
    }
    github_provider.expects(:fetch_latest_release_notes).returns(incomplete_data)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Test Release"
    # Should not crash even with nil values
  end
end
