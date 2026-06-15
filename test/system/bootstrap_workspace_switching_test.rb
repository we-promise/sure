require "application_system_test_case"

class BootstrapWorkspaceSwitchingTest < ApplicationSystemTestCase
  setup do
    @bootstrap_password = "BootstrapPass1!"
    passwords = (
      PlatformBootstrap::MultiCompanyOwners::OWNERS +
      PlatformBootstrap::MultiCompanyOwners::FAMILY_ADMINS
    ).to_h { |operator| [ operator.fetch(:email), @bootstrap_password ] }

    PlatformBootstrap::MultiCompanyOwners.new(passwords: passwords).call

    @bootstrap_super_admin = User.find_by!(email: "adminf0@bookeepz.net")
  end

  test "bootstrap super admin switches into a company workspace when choosing a company" do
    visit new_session_path
    within %(form[action='#{sessions_path}']) do
      fill_in "Email", with: @bootstrap_super_admin.email
      fill_in "Password", with: @bootstrap_password
      click_on "Log in"
    end

    assert_selector "h1", text: "Welcome back, F0-SU-1"

    select "Risingstone ventures pvt ltd", from: "Company"

    assert_selector "h1", text: "Welcome back, RS-VENTURES-ADMIN"
    assert_selector "span", text: "Current company:"
    assert_selector "span", text: "Risingstone ventures pvt ltd"
    assert_selector "button", text: "Exit workspace"
  end
end
