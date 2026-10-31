require "test_helper"

class UsersHelperTest < ActionView::TestCase
  test "users without an attachment have no avatar URL" do
    assert_nil user_avatar_url(users(:family_admin))
  end

  test "returns small variants by default and originals when requested" do
    user = users(:family_admin)
    user.profile_image.attach(io: file_fixture("profile_image.png").open, filename: "avatar.png", content_type: "image/png")
    variant = user.profile_image.variant(:small).processed
    ActiveStorage::Current.url_options = { host: "www.example.com", protocol: "http" }

    freeze_time do
      assert_equal variant.url, user_avatar_url(user)
      assert_equal user.profile_image.url, user_avatar_url(user, variant: nil)
    end
  ensure
    ActiveStorage::Current.reset
  end
end
