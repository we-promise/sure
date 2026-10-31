require "test_helper"

class UserAvatarStorageTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.profile_image.attach(io: file_fixture("profile_image.png").open, filename: "avatar.png", content_type: "image/png")
    sign_in @user
  end

  [ :root_path, :settings_profile_path, :onboarding_path ].each do |route|
    [ ArgumentError, ActiveStorage::FileNotFoundError, Timeout::Error ].each do |error_class|
      test "#{route} remains usable when avatar storage raises #{error_class}" do
        attachment_id = @user.profile_image.attachment.id
        blob_id = @user.profile_image.blob.id
        ActiveStorage::VariantWithRecord.any_instance.stubs(:url).raises(error_class, "private-storage-detail")
        ActiveStorage::Blob.any_instance.stubs(:url).raises(error_class, "private-storage-detail")

        get public_send(route)

        assert_response :success
        assert_select "img[data-controller='avatar']", count: 0
        assert_includes response.body, @user.initials
        assert_no_match "private-storage-detail", response.body
        assert ActiveStorage::Attachment.exists?(attachment_id)
        assert ActiveStorage::Blob.exists?(blob_id)
        unless route == :root_path
          assert_select "input[type='file'][name='user[profile_image]']"
          assert_select "input[name='user[delete_profile_image]'][value='0']"
          assert_select "[data-profile-image-preview-target='attachedImage']", text: @user.initials
        end
      end
    end
  end

  test "profile remains usable when another household member has an unavailable avatar" do
    member = users(:family_member)
    member.profile_image.attach(io: file_fixture("profile_image.png").open, filename: "member.png", content_type: "image/png")
    @user.profile_image.purge
    ActiveStorage::VariantWithRecord.any_instance.stubs(:url).raises(ActiveStorage::FileNotFoundError)

    get settings_profile_path

    assert_response :success
    assert_includes response.body, member.initials
    assert member.reload.profile_image.attached?
  end
end
