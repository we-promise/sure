require "application_system_test_case"

class AdminUserAvatarsTest < ApplicationSystemTestCase
  setup do
    @target = users(:family_member)
    @target.profile_image.attach(
      io: file_fixture("profile_image.png").open,
      filename: "avatar.png",
      content_type: "image/png"
    )
    @variant = @target.profile_image.variant(:small).processed
  end

  test "missing variant file leaves initials and user management available" do
    blob = @variant.image.blob
    blob.service.delete(blob.key)
    assert_not blob.service.exist?(blob.key)

    visit_target_row do
      assert_selector "img[data-controller='avatar'][hidden]", visible: :all
      assert_no_selector "img", visible: true
      assert_text @target.initials
      assert_selector "button[aria-haspopup='dialog']"
    end
    assert @target.reload.profile_image.attached?
    assert ActiveStorage::Blob.exists?(blob.id)
  end

  test "available variant remains visible" do
    visit_target_row do
      assert_selector "img[data-controller='avatar']:not([hidden])", visible: true do |image|
        image.evaluate_script("this.complete && this.naturalWidth > 0")
      end
    end
  end

  private

    def visit_target_row(&block)
      sign_in users(:sure_support_staff)
      visit admin_users_path
      find("details", text: @target.family.name).find("summary").click
      row = find("tr", text: @target.email)
      row.scroll_to(:center)
      within(row, &block)
    end
end
