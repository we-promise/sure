require "test_helper"

class Settings::AppearancesControllerTest < ActionDispatch::IntegrationTest
  test "admin can enable auto-generate transaction names for the whole family" do
    sign_in users(:family_admin)
    families(:dylan_family).update!(auto_generate_transaction_names: false)

    patch settings_appearance_path, params: { family: { auto_generate_transaction_names: "1" } }

    assert_redirected_to settings_appearance_path
    assert families(:dylan_family).reload.auto_generate_transaction_names?
  end

  test "admin can disable auto-generate transaction names for the whole family" do
    sign_in users(:family_admin)
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    patch settings_appearance_path, params: { family: { auto_generate_transaction_names: "0" } }

    assert_redirected_to settings_appearance_path
    assert_not families(:dylan_family).reload.auto_generate_transaction_names?
  end

  test "non-admin family member cannot change the family-wide setting" do
    sign_in users(:family_member)
    families(:dylan_family).update!(auto_generate_transaction_names: false)

    patch settings_appearance_path, params: { family: { auto_generate_transaction_names: "1" } }

    assert_redirected_to settings_appearance_path
    assert_not families(:dylan_family).reload.auto_generate_transaction_names?
  end

  test "the privacy mode section offers the chart blur toggle, on by default" do
    sign_in users(:family_member)

    get settings_appearance_path

    assert_response :ok
    assert_select "input#user_privacy_mode_blur_charts[type=checkbox][checked]"
  end

  test "a member can keep chart shapes visible in privacy mode and change back" do
    user = users(:family_member)
    sign_in user

    patch settings_appearance_path, params: { user: { privacy_mode_blur_charts: "0" } }

    assert_redirected_to settings_appearance_path
    assert_not user.reload.privacy_mode_blur_charts?

    patch settings_appearance_path, params: { user: { privacy_mode_blur_charts: "1" } }

    assert user.reload.privacy_mode_blur_charts?
  end

  test "a form without the toggle leaves the privacy preference alone" do
    user = users(:family_member)
    user.update!(preferences: (user.preferences || {}).merge("privacy_mode_blur_charts" => false))
    sign_in user

    patch settings_appearance_path, params: { user: { show_split_grouped: "1" } }

    assert_not user.reload.privacy_mode_blur_charts?
  end

  # The CSS keys the numbers-only behaviour off a class on <html>, so the
  # layout must carry the preference on every page.
  test "the layout marks the page when privacy mode keeps chart shapes visible" do
    user = users(:family_member)
    sign_in user

    get settings_appearance_path
    assert_select "html.privacy-numbers-only", count: 0
    # The SVG filter that blurs amounts inside charts must be on every page.
    assert_select "svg filter#privacy-mode-blur", count: 1

    user.update!(preferences: (user.preferences || {}).merge("privacy_mode_blur_charts" => false))
    get settings_appearance_path
    assert_select "html.privacy-numbers-only", count: 1
  end

  # Turbo keeps <html> across visits, so the application layout's privacy-mode
  # controller carries the preference too and re-applies the class whenever a
  # page using that layout renders; the dashboard is where the charts are.
  test "the application layout hands the privacy preference to the client" do
    user = users(:family_member)
    sign_in user

    get root_path
    assert_select "[data-controller~=privacy-mode][data-privacy-mode-numbers-only-value='false']"

    user.update!(preferences: (user.preferences || {}).merge("privacy_mode_blur_charts" => false))
    get root_path
    assert_select "[data-controller~=privacy-mode][data-privacy-mode-numbers-only-value='true']"
  end

  # The settings layout has no privacy-mode controller, so the toggle itself
  # mirrors the choice onto <html> and drops Turbo's snapshot cache.
  test "the toggle applies the preference on the client as soon as it changes" do
    sign_in users(:family_member)

    get settings_appearance_path
    assert_select "form[data-controller~=privacy-mode-preference] input#user_privacy_mode_blur_charts[data-action~='change->privacy-mode-preference#apply']"
  end
end
