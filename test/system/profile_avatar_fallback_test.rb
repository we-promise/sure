require "application_system_test_case"

class ProfileAvatarFallbackTest < ApplicationSystemTestCase
  test "missing original avatar leaves initials and replacement controls usable" do
    user = users(:family_admin)
    sign_in user
    user.profile_image.attach(io: file_fixture("profile_image.png").open, filename: "avatar.png", content_type: "image/png")
    user.profile_image.variant(:small).processed
    blob = user.profile_image.blob
    blob.service.delete(blob.key)

    visit settings_profile_path

    within "[data-profile-image-preview-target='attachedImage']" do
      assert_selector "img[data-controller='avatar'][hidden]", visible: :all
      assert_no_selector "img", visible: true
      assert_text user.initials
    end
    assert user.reload.profile_image.attached?
    assert ActiveStorage::Blob.exists?(blob.id)

    attach_file "user[profile_image]", file_fixture("profile_image.png"), make_visible: true
    within "[data-profile-image-preview-target='previewImage']" do
      assert_selector "img", visible: true do |image|
        image.evaluate_script("this.complete && this.naturalWidth > 0")
      end
    end
    assert_selector "input[name='user[delete_profile_image]'][value='0']", visible: :all
  end
end
