require "application_system_test_case"

class LogoFallbackTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false)
    # A same-origin missing image exercises the real browser error event without
    # depending on Brandfetch or making requests with a real client ID.
    Account.any_instance.stubs(:logo_url).returns("/missing-logo-for-fallback-test.png")
    sign_in @user
  end

  test "failed account logos show initials and recover when a valid image loads" do
    visit accounts_path
    assert_selector "[data-controller='image-fallback'] [data-image-fallback-target='fallback']"
    logo = first("[data-controller='image-fallback']", minimum: 1)
    within logo do
      assert_selector "[data-image-fallback-target='fallback']"
      assert_no_selector "img", visible: true
    end

    # Exercise the cached-failure path: reconnect after the image already failed.
    page.execute_script("arguments[0].removeAttribute('data-controller')", logo)
    page.execute_script("arguments[0].querySelector('img').hidden = false; arguments[0].querySelector('[data-image-fallback-target=fallback]').hidden = true", logo)
    within(logo) { assert_selector "img", visible: true }
    page.execute_script("arguments[0].setAttribute('data-controller', 'image-fallback')", logo)
    within(logo) { assert_selector "[data-image-fallback-target='fallback']" }

    page.execute_script(<<~JS, logo)
      const image = arguments[0].querySelector('img');
      image.src = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="green"/></svg>');
    JS
    within logo do
      assert_selector "img", visible: true
      assert_no_selector "[data-image-fallback-target='fallback']", visible: true
    end
  end
end
