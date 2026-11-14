require "application_system_test_case"

# An institution entry is a <details> inside its group's wrapper, which carries
# the group's data-group-key. The script that restores the sidebar's open
# groups after a Turbo visit must keep the two apart: a closed entry must not
# close its group, and an open one must stay open.
class SidebarInstitutionBundlesTest < ApplicationSystemTestCase
  include EntriesTestHelper

  GROUP = "#asset_depository details:not([data-institution-bundle])".freeze
  BUNDLE = "#asset_depository details[data-institution-bundle='wise|']".freeze

  setup do
    @user = users(:family_admin)
    family = @user.family
    %w[EUR GBP].each do |currency|
      family.accounts.create!(name: "Wise #{currency}", balance: 10, currency: family.currency, institution_name: "Wise", accountable: Depository.new)
    end
    @brokerage = family.accounts.create!(name: "Bundle test brokerage", balance: 5, currency: family.currency, accountable: Investment.new)
    sign_in @user
  end

  test "a group and the institution entry inside it keep their own open state across a visit" do
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    assert_selector "#{GROUP}[open]"
    assert_no_selector "#{BUNDLE}[open]"

    within("#asset_investment") do
      find("summary", match: :first).click
      click_link "Bundle test brokerage"
    end
    assert_selector "#asset_investment a[data-active-account][href='#{account_path(@brokerage)}']"
    assert_equal [ true, false ], open_states, "the closed entry closed its group"

    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click
    first(:link, "Home").click
    assert_no_selector "#sidebar-scroll [data-active-account]", visible: :all
    assert_equal [ true, true ], open_states, "the open entry was closed"
  end

  # The mobile overlay holds its own copy of the sidebar.
  test "an institution entry opened in the mobile sidebar stays open across a visit" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit root_path
    mobile = "[data-app-layout-target='mobileSidebar']"
    find("[data-action='app-layout#openMobileSidebar']").click
    within(mobile) do
      within("#mobile_asset_depository") { find("summary", match: :first).click }
      find("details[data-institution-bundle='wise|'] > summary [data-institution-bundle-toggle]").click
      assert_selector "details[data-institution-bundle='wise|'][open]"
      within("#mobile_asset_investment") do
        find("summary", match: :first).click
        click_link "Bundle test brokerage"
      end
    end
    assert_current_path account_path(@brokerage)

    open = evaluate_script(%(document.querySelector("#{mobile} #mobile_asset_depository details[data-institution-bundle='wise|']").open))
    assert open, "the institution entry opened in the mobile sidebar was closed by the visit"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1000) rescue nil
  end

  test "an institution's name leads to its page, and its chevron opens it in place" do
    create_transaction(account: Account.find_by!(name: "Wise EUR"), name: "Wise coffee", currency: @user.family.currency)
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }

    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click
    assert_selector "#{BUNDLE}[open]"
    assert_current_path root_path

    find("#{BUNDLE} > summary a").click
    assert_selector "main h2", text: "Wise"
    assert_current_path(%r{\A/institution_groups/depository-})
    within("#institution-group-activity") { assert_text "Wise coffee" }
    assert_selector "#{BUNDLE} > summary a[data-active-account]"
  end

  test "settings saved on an institution's page change its currency in the sidebar" do
    family = @user.family
    ExchangeRate.create!(from_currency: family.currency, to_currency: "CHF", date: Date.current, rate: 2)
    open_settings

    within("dialog") do
      select "Swiss Franc (CHF)", from: I18n.t("institution_groups.form.currency")
      click_on I18n.t("institution_groups.form.save")
    end

    assert_selector "main h2", text: "Wise"
    within("#{BUNDLE} > summary") { assert_text Money.new(40, "CHF").format }
  end

  test "renaming an institution and changing its URL in its settings changes them in the sidebar and on its accounts" do
    open_settings

    within("dialog") do
      fill_in I18n.t("institution_groups.form.name"), with: "Wise Business"
      fill_in I18n.t("institution_groups.form.institution_domain"), with: "wise.com"
      click_on I18n.t("institution_groups.form.save")
    end

    renamed = "#asset_depository details[data-institution-bundle='wise business|wise.com']"
    assert_selector "main h2", text: "Wise Business"
    assert_current_path(%r{\A/institution_groups/depository-#{Digest::MD5.hexdigest("wise business|wise.com")[0, 12]}})
    within("#{renamed} > summary") { assert_text "Wise Business" }
    assert_no_selector BUNDLE

    visit accounts_path
    @user.family.accounts.where(name: [ "Wise EUR", "Wise GBP" ]).each do |account|
      assert_selector "##{ActionView::RecordIdentifier.dom_id(account)}", text: "Wise Business"
    end
    assert_equal [ [ "Wise Business", "wise.com" ] ] * 2, wise_accounts.map { |account| account.slice(:institution_name, :institution_domain).values }
  end

  test "an icon uploaded in an institution's settings shows on its entry, its page and every account's page" do
    open_settings

    within("dialog") do
      attach_file "institution_group[logo]", file_fixture("square-placeholder.png")
      click_on I18n.t("institution_groups.form.save")
    end

    assert_selector "main header img[src$='/square-placeholder.png']"
    within("#{BUNDLE} > summary") { assert_selector "img[src$='/square-placeholder.png']" }
    blobs = wise_accounts.map { |account| account.logo.blob }
    assert_equal 1, blobs.uniq.size
    assert_equal blobs.first, @user.family.institution_groups.sole.logo.blob
    assert ActiveStorage::Blob.service.exist?(blobs.first.key), "the image is stored once, for all of them"

    wise_accounts.each do |account|
      visit account_path(account)
      assert_selector "main header img[src$='/square-placeholder.png']"
    end
  end

  test "removing one account's icon in its own form changes that account only" do
    eur, gbp = wise_accounts
    eur.logo.attach(io: file_fixture("profile_image.png").open, filename: "eur.png", content_type: "image/png")
    gbp.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "gbp.png", content_type: "image/png")
    # Signing in formed the group before the accounts had icons; it forms again, taking EUR's.
    @user.family.institution_groups.destroy_all
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    within("#{BUNDLE} > summary") { assert_selector "img[src$='/eur.png']" }
    # The account changed now comes first; the group still keeps the icon it formed with.
    @user.update!(default_account_order: "name_desc")

    visit account_path(gbp)
    open_account_edit_dialog
    within("dialog") do
      find("summary", text: I18n.t("accounts.form.additional_details")).click
      click_on I18n.t("accounts.logo_field.remove")
      find("form[action='#{depository_path(gbp)}'] [type=submit]:not([form])").click
    end

    # The form posts without Turbo and comes back to the account with a notice.
    assert_text I18n.t("accounts.update.success", type: "Depository")
    assert_not gbp.reload.logo.attached?
    assert_equal "eur.png", eur.reload.logo.blob.filename.to_s
    assert_equal "eur.png", @user.family.institution_groups.reload.sole.logo.blob.filename.to_s

    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    within("#{BUNDLE} > summary") { assert_selector "img[src$='/eur.png']" }
    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click
    # The accounts under the entry show no icons of their own; their pages do.
    within(BUNDLE) do
      assert_selector "a[href='#{account_path(eur)}']"
      assert_selector "a[href='#{account_path(gbp)}']"
    end
    visit account_path(eur)
    assert_selector "main header img[src$='/eur.png']"
  end

  test "an institution entry's total lines up with the account rows' balances" do
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click

    edges = page.evaluate_script(<<~JS)
      (() => {
        const group = document.querySelector("#asset_depository")
        const right = (el) => Math.round(el.getBoundingClientRect().right)
        const total = group.querySelector("details[data-institution-bundle='wise|'] > summary .privacy-sensitive")
        const row = Array.from(group.querySelectorAll("a[href^='/accounts/'] .privacy-sensitive")).find((el) => !el.closest("[data-institution-bundle]"))
        return [right(total), right(row)]
      })()
    JS

    assert_equal edges.second, edges.first, "the entry's total is not aligned with the rows' balances"
  end

  test "clicking an institution entry's row opens it in place" do
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }

    find("#{BUNDLE} > summary .privacy-sensitive").click

    assert_selector "#{BUNDLE}[open]"
    assert_current_path root_path
  end

  test "an institution entry draws its accounts' combined sparkline" do
    @user.family.accounts.where(institution_name: "Wise").each do |account|
      [ 20, 0 ].each { |days| account.balances.create!(date: days.days.ago.to_date, balance: 10 + days, start_cash_balance: 10 + days, currency: account.currency) }
    end

    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }

    assert_selector "#{BUNDLE} > summary turbo-frame[complete] [data-controller='time-series-chart'] svg path", wait: 10
  end

  private
    def wise_accounts
      @user.family.accounts.where(name: [ "Wise EUR", "Wise GBP" ]).order(:name).to_a
    end

    # As AccountsTest#open_account_edit_dialog: the account page may morph
    # under the menu just after it loads, so try again until the form shows.
    def open_account_edit_dialog
      3.times do
        return if has_field?("Account name", wait: 0)

        begin
          within_testid("account-menu") do
            find("button").click unless has_selector?("[role='menu']", visible: true, wait: 0)
            click_on "Edit"
          end
        rescue Selenium::WebDriver::Error::WebDriverError => e
          raise unless e.message.match?(/does not belong to the document|stale element reference/i)
          next
        end
        return if has_field?("Account name", wait: 2)
      end
      assert_field "Account name"
    end

    def open_settings
      visit root_path
      within("#asset_depository") { find("summary", match: :first).click }
      find("#{BUNDLE} > summary a").click
      assert_selector "main h2", text: "Wise"
      click_on I18n.t("institution_groups.header.settings")
    end

    def open_states
      evaluate_script(%([#{GROUP.to_json}, #{BUNDLE.to_json}].map(function (selector) { return document.querySelector(selector).open; })))
    end
end
