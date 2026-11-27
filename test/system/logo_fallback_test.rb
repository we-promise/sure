require "application_system_test_case"

class LogoFallbackTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false)
    login_as @user
  end

  test "failed merchant logos remove themselves and reveal local initials" do
    FamilyMerchant.any_instance.stubs(:logo_url).returns("/missing-logo-for-fallback-test.png")
    visit family_merchants_path

    within "tr", text: "Netflix" do
      assert_selector "span.relative.overflow-hidden", text: "N"
      assert_no_selector "span.relative img", visible: :all
      assert_no_selector "[data-controller='image-fallback']", visible: :all
    end
  end

  test "missing merchant logos use the same local initial" do
    FamilyMerchant.any_instance.stubs(:logo_url).returns(nil)
    visit family_merchants_path

    within "tr", text: "Netflix" do
      assert_selector "span.relative.overflow-hidden.w-8.h-8", text: "N"
      assert_no_selector "span.relative img", visible: :all
    end
  end

  test "successful merchant logos cover the initials" do
    image = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E%3Crect width='40' height='40' fill='green'/%3E%3C/svg%3E"
    FamilyMerchant.any_instance.stubs(:logo_url).returns(image)
    visit family_merchants_path

    within "tr", text: "Netflix" do
      logo = find("span.relative.overflow-hidden")
      assert_selector "img.bg-container[onerror='this.remove()']"
      wait_until { logo.find("img").evaluate_script("this.complete && this.naturalWidth > 0") }
      assert logo.find("img").evaluate_script("this.complete && this.naturalWidth > 0")
    end
  end
end
