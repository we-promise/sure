require "test_helper"

class InstitutionGroupsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @eur = create_account("Wise EUR", @family)
    @gbp = create_account("Wise GBP", @family)
  end

  test "show lists the accounts and merges their activity, newest first" do
    create_transaction(account: @eur, name: "Older EUR coffee", date: 3.days.ago.to_date, currency: @family.currency)
    create_transaction(account: @gbp, name: "Newer GBP lunch", date: 1.day.ago.to_date, currency: @family.currency)
    create_transaction(account: accounts(:depository), name: "Not at Wise", date: Date.current)

    get institution_group_url(bundle_slug)

    assert_response :success
    assert_select "h2", text: "Wise"
    assert_select "#institution-group-accounts a[href='#{account_path(@eur)}']"
    assert_select "#institution-group-accounts a[href='#{account_path(@gbp)}']"
    assert_select "#institution-group-chart[data-time-series-chart-selectable-value='true']"
    names = css_select("#institution-group-activity a").map { |link| link.text.strip }
    assert_operator names.index("Newer GBP lunch"), :<, names.index("Older EUR coffee")
    assert_not_includes names, "Not at Wise"
  end

  test "a transfer between two of the institution's accounts is listed and counted once, before paging" do
    create_transfer(from_account: @eur, to_account: @gbp, amount: 25, currency: @family.currency)
    # Ten rows to show (the transfer once, the rest the accounts' other
    # entries, their opening balances included): exactly one page.
    shown = Entry.where(account_id: [ @eur.id, @gbp.id ]).count - 1
    assert_operator shown, :<=, 10
    (10 - shown).times { |i| create_transaction(account: @eur, name: "Coffee #{i}", date: 2.days.ago.to_date, currency: @family.currency) }

    get institution_group_url(bundle_slug, per_page: 10)

    rows = css_select("#institution-group-activity [id^='entry_']").map { |row| row["id"] }.grep(/\Aentry_\h{8}-/).uniq
    assert_equal 10, rows.size, "the transfer's second leg took a row of the page: #{rows.size} rows"
    assert_select "#institution-group-activity a[href*='page=2']", count: 0
  end

  test "the accounts list shows each account's reconciliation status once manual reconciliation is on" do
    create_transaction(account: @eur, name: "Not yet reconciled", date: 1.day.ago.to_date, currency: @family.currency)
    needs_attention = /#{Regexp.escape(I18n.t("accounts.reconciliation_indicator.needs_attention"))}/

    get institution_group_url(bundle_slug)
    assert_select "#institution-group-accounts li", text: needs_attention, count: 0

    @family.update!(manual_reconciliation: true)
    get institution_group_url(bundle_slug)
    assert_select "#institution-group-accounts li", text: needs_attention, count: 1
    assert_select "#institution-group-accounts li a[href='#{account_path(@eur)}']", text: needs_attention
  end

  test "the sparkline is the accounts' combined balance over the last 30 days" do
    [ @eur, @gbp ].each_with_index do |account, index|
      [ 30, 0 ].each { |days| account.balances.create!(date: days.days.ago.to_date, balance: 10 * (index + 1) + days, start_cash_balance: 10 * (index + 1) + days, currency: @family.currency) }
    end

    get sparkline_institution_group_url(bundle_slug)

    assert_response :success
    assert_select "turbo-frame##{bundle_slug}_sparkline"
    series = JSON.parse(css_select("[data-controller='time-series-chart']").first["data-time-series-chart-data-value"])
    assert_equal [ 90, 30 ], [ series["values"].first, series["values"].last ].map { |point| point.dig("value", "amount").to_d.to_i }
  end

  test "a sparkline URL carrying the current version may be reused by the browser" do
    bundle = @family.balance_sheet.institution_bundle(bundle_slug)

    get sparkline_institution_group_url(bundle_slug, v: bundle.sparkline_version)
    assert_includes response.headers["Cache-Control"], "max-age=86400"

    get sparkline_institution_group_url(bundle_slug, v: "stale")
    assert_not_includes response.headers["Cache-Control"].to_s, "max-age=86400"
  end

  test "an unknown bundle has no sparkline" do
    get sparkline_institution_group_url("depository-000000000000")

    assert_response :not_found
  end

  test "the settings form shows the name and domain the accounts give" do
    get edit_institution_group_url(bundle_slug)

    assert_select "input[name='institution_group[name]'][value='Wise']"
    assert_select "input[name='institution_group[institution_domain]'][value='wise.com']"
  end

  test "saving the inherited name and domain unchanged keeps the bundle following its accounts" do
    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", institution_domain: "wise.com", currency: "" } }

    assert_redirected_to institution_group_url(bundle_slug)
    assert_equal [ nil, nil ], [ group.name, group.institution_domain ]
    assert_equal [ [ "Wise", "wise.com" ] ] * 2, [ @eur, @gbp ].map { |account| account.reload.slice(:institution_name, :institution_domain).values }
  end

  test "a range picked on the chart narrows the activity, and a preset period does not" do
    create_transaction(account: @eur, name: "Inside the range", date: 5.days.ago.to_date, currency: @family.currency)
    create_transaction(account: @gbp, name: "Before the range", date: 20.days.ago.to_date, currency: @family.currency)

    get institution_group_url(bundle_slug, start_date: 10.days.ago.to_date, end_date: Date.current)

    assert_select "#institution-group-activity-filters a[href='#{institution_group_path(bundle_slug)}']"
    assert_select "#institution-group-activity", text: /Inside the range/
    assert_select "#institution-group-activity", text: /Before the range/, count: 0

    get institution_group_url(bundle_slug, period: "last_30_days")

    assert_select "#institution-group-activity-filters", count: 0
    assert_select "#institution-group-activity", text: /Before the range/
  end

  test "show is not found for an unknown slug or another family's institution" do
    get institution_group_url("depository-000000000000")
    assert_response :not_found

    # Another family bundles its Wise accounts under the same slug; this
    # family no longer has two.
    2.times { |index| create_account("Other Wise #{index}", families(:empty)) }
    @eur.update!(institution_name: "Revolut")
    get institution_group_url(bundle_slug)
    assert_response :not_found
  end

  test "a member sees the institution's accounts shared with them only" do
    third = create_account("Wise USD", @family)
    create_transaction(account: third, name: "Unshared spend", currency: @family.currency)
    create_transaction(account: @eur, name: "Shared spend", currency: @family.currency)
    [ @eur, @gbp ].each { |account| account.account_shares.create!(user: users(:family_member), permission: "read_only") }
    sign_in users(:family_member)

    get institution_group_url(bundle_slug)

    assert_response :success
    assert_select "#institution-group-accounts a[href='#{account_path(third)}']", count: 0
    assert_select "#institution-group-activity", text: /Shared spend/
    assert_select "#institution-group-activity", text: /Unshared spend/, count: 0

    AccountShare.where(account: @gbp, user: users(:family_member)).destroy_all
    get institution_group_url(bundle_slug)
    assert_response :not_found
  end

  test "edit shows the account form's icon picker with the group's icon, searching for the institution" do
    blob = attach_logo(@eur)

    get edit_institution_group_url(bundle_slug)

    assert_response :success
    assert_select "form[enctype='multipart/form-data'][action='#{institution_group_path(bundle_slug)}']" do
      assert_select "[data-controller=account-logo-picker][data-account-logo-picker-domain-field-value='institution_group[institution_domain]'][data-account-logo-picker-name-field-value='institution_group[name]']" do
        assert_select "turbo-frame#logo_field_account" do
          assert_select "[data-account-logo-picker-target=image] img[src=?]", @eur.stored_logo_url
          assert_select "button[form=logo_options_account][data-action='account-logo-picker#search']"
          assert_select "button[data-action='account-logo-picker#remove']"
        end
        assert_select "input[type=hidden][name='institution_group[logo_choice]'][data-account-logo-picker-target=choice]"
        assert_select "input[type=file][name='institution_group[logo]']"
      end
    end
    assert_select "form#logo_options_account[action=?][data-turbo-frame=logo_field_account]", logo_options_institution_group_path(bundle_slug)
    assert_select "select[name='institution_group[logo_account_id]']", count: 0
    assert_equal blob, group.logo.blob, "the group took its first account's icon when it formed"
  end

  test "the group takes its icon from its first account in the user's Default Account Order when it forms" do
    @eur.update!(institution_name: "wise")
    attach_logo(@eur, "profile_image.png")
    gbp_blob = attach_logo(@gbp)
    @user.update!(default_account_order: "name_desc")

    get edit_institution_group_url(bundle_slug)
    assert_select "input[name='institution_group[name]'][value='Wise']"
    assert_select "turbo-frame#logo_field_account [data-account-logo-picker-target=image] img[src=?]", @gbp.stored_logo_url
    assert_equal gbp_blob, group.logo.blob

    # Afterwards the group keeps its icon, while the name follows the first account.
    @user.update!(default_account_order: "name_asc")
    get institution_group_url(bundle_slug)
    assert_select "header h2", text: "wise"
    assert_select "header img[src=?]", @gbp.stored_logo_url

    # Saved unchanged, the defaults stay blank: the bundle keeps following its accounts.
    patch institution_group_url(bundle_slug), params: { institution_group: { name: "wise", institution_domain: "wise.com", currency: "" } }
    assert_redirected_to institution_group_url(bundle_slug)
    assert_equal [ nil, nil ], group.slice(:name, :institution_domain).values
    assert_equal gbp_blob, group.logo.blob
  end

  test "the icon picker searches the domain and name typed in the settings, without saving them" do
    icon = Account::LogoFetcher::Icon.new(key: "appstore:1", source: "appstore", name: "Krungsri", body: file_fixture("square-placeholder.png").binread,
                                          size: 512, content_type: "image/png", extension: "png")
    Account::LogoFetcher.any_instance.expects(:candidates).returns([ icon ])

    get logo_options_institution_group_url(bundle_slug), params: { institution_domain: "https://www.krungsri.com/", institution_name: "Krungsri" },
        headers: { "Turbo-Frame" => "logo_field_account" }

    assert_response :success
    assert_select "turbo-frame#logo_field_account button[data-account-logo-picker-choice-param='appstore:1']"
    assert_equal [ "Wise", "wise.com" ], @eur.reload.slice(:institution_name, :institution_domain).values

    get logo_options_institution_group_url(bundle_slug)
    assert_redirected_to institution_group_url(bundle_slug)
  end

  test "saving writes the name and URL to every account and moves the settings with them" do
    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "https://wise.co.uk/", currency: "EUR" } }

    new_slug = bundle_slug("wise business|wise.co.uk")
    assert_redirected_to institution_group_url(new_slug)
    [ @eur, @gbp ].each(&:reload)
    assert_equal [ [ "Wise Business", "wise.co.uk" ] ] * 2, [ @eur, @gbp ].map { |account| [ account.institution_name, account.institution_domain ] }
    assert_equal [ "Wise EUR", "Wise GBP" ], [ @eur.name, @gbp.name ]
    assert @eur.locked?("institution_name"), "a provider sync must not undo the rename"

    settings = @family.institution_groups.sole
    assert_equal [ "wise business|wise.co.uk", nil, nil, "EUR" ], [ settings.key, settings.name, settings.institution_domain, settings.currency ]

    get institution_group_url(bundle_slug)
    assert_response :not_found
    get institution_group_url(new_slug)
    assert_select "h2", text: "Wise Business"

    patch institution_group_url(new_slug), params: { institution_group: { name: "", institution_domain: "", currency: "" } }

    assert_redirected_to institution_group_url(new_slug)
    assert_equal [ "wise business|wise.co.uk", nil ], [ settings.reload.key, settings.currency ]
    assert_equal "Wise Business", @eur.reload.institution_name, "a blank name leaves the accounts' names"
  end

  test "saving renames the institution's accounts of every type, so its entries keep one row of settings" do
    cards = %w[Visa Amex].map do |name|
      @family.accounts.create!(name: "Wise #{name}", balance: 10, currency: @family.currency, institution_name: "Wise",
                               institution_domain: "wise.com", accountable: CreditCard.new)
    end

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "wise.com", currency: "" } }

    assert_equal [ "Wise Business" ] * 4, [ @eur, @gbp, *cards ].map { |account| account.reload.institution_name }
    get accounts_url
    assert_equal [ "wise business|wise.com" ], @family.institution_groups.reload.map(&:key), "the cards' entry formed a second row of settings"
  end

  test "a rename into an institution that has a group merges into it, keeping its icon" do
    other_logo = ActiveStorage::Blob.create_and_upload!(io: file_fixture("profile_image.png").open, filename: "other.png", content_type: "image/png")
    other = @family.institution_groups.create!(key: "wise business|wise.com", name: "Old override", currency: "CHF", logo: other_logo)
    @family.institution_groups.create!(key: "wise|wise.com", currency: "EUR")

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", currency: "" } }

    assert_redirected_to institution_group_url(bundle_slug("wise business|wise.com"))
    assert_equal [ other ], @family.institution_groups.reload.to_a
    assert_equal [ nil, "CHF", other_logo ], [ other.reload.name, other.currency, other.logo.blob ]
  end

  test "a rename onto another institution with an uploaded icon gives the icon to that institution's accounts too" do
    destination = %w[CHF JPY].map do |currency|
      @family.accounts.create!(name: "Wise Business #{currency}", balance: 10, currency: @family.currency, institution_name: "Wise Business",
                               institution_domain: "wise.com", accountable: Depository.new)
    end

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "wise.com",
                                                                             logo: fixture_file_upload("square-placeholder.png", "image/png") } }

    assert_redirected_to institution_group_url(bundle_slug("wise business|wise.com"))
    blob = @eur.reload.logo.blob
    assert_equal "square-placeholder.png", blob.filename.to_s
    assert_equal [ blob, blob ], destination.map { |account| account.reload.logo.blob }, "the merged institution's accounts kept their own icons"
  end

  test "a member who can only view the institution's accounts renames nothing, even onto accounts they control" do
    member = users(:family_member)
    [ @eur, @gbp ].each { |account| account.account_shares.create!(user: member, permission: "read_only") }
    destination = %w[CHF JPY].map do |currency|
      @family.accounts.create!(name: "Wise Business #{currency}", balance: 10, currency: @family.currency, institution_name: "Wise Business",
                               institution_domain: "wise.com", accountable: Depository.new, owner: member)
    end
    destination_blobs = destination.map { |account| attach_logo(account) }
    sign_in member
    get institution_group_url(bundle_slug)

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "wise.com",
                                                                             logo: fixture_file_upload("profile_image.png", "image/png") } }

    assert_equal [ "Wise" ] * 2, [ @eur, @gbp ].map { |account| account.reload.institution_name }
    assert_equal destination_blobs, destination.map { |account| account.reload.logo.blob }, "the destination took the icon"
    assert group, "the institution's settings moved away"
  end

  test "an icon uploaded in the settings is stored once and given to the group and every account the user can edit" do
    usd = create_account("Wise USD", @family)
    usd_blob = attach_logo(usd, "profile_image.png")
    member = users(:family_member)
    { @eur => "full_control", @gbp => "full_control", usd => "read_only" }.each do |account, permission|
      account.account_shares.create!(user: member, permission: permission)
    end
    @gbp.update!(logo_selection: :brandfetch)
    sign_in member
    get institution_group_url(bundle_slug)

    assert_difference -> { ActiveStorage::Blob.count }, 1 do
      assert_no_enqueued_jobs only: AccountLogoFetchJob do
        patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", institution_domain: "wise.com",
                                                                                 logo: fixture_file_upload("square-placeholder.png", "image/png") } }
      end
    end

    assert_redirected_to institution_group_url(bundle_slug)
    blob = @eur.reload.logo.blob
    assert_equal "square-placeholder.png", blob.filename.to_s
    assert_equal [ blob, blob ], [ @gbp.reload.logo.blob, group.logo.blob ]
    assert @gbp.logo_automatic?, "an upload is shown instead of Brandfetch, as in the account form"
    assert_equal usd_blob, usd.reload.logo.blob, "an account the user may only view keeps its icon"
  end

  test "an icon picked in the settings is downloaded once and given to the group and every account" do
    icon = Account::LogoFetcher::Icon.new(key: "appstore:1", source: "appstore", name: "Wise", body: file_fixture("square-placeholder.png").binread,
                                          size: 512, content_type: "image/png", extension: "png")
    Account::LogoFetcher.any_instance.expects(:icon).once.with("appstore:1").returns(icon)

    assert_no_enqueued_jobs only: AccountLogoFetchJob do
      patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", institution_domain: "wise.com", logo_choice: "appstore:1" } }
    end

    assert_redirected_to institution_group_url(bundle_slug)
    assert_nil flash[:alert]
    blob = @eur.reload.logo.blob
    assert_equal [ blob, blob ], [ @gbp.reload.logo.blob, group.logo.blob ]
    assert_equal "appstore:1", @gbp.logo_key
  end

  test "choosing Brandfetch in the settings shows it on the group and every account" do
    Setting.stubs(:brand_fetch_client_id).returns("client-id")
    attach_logo(@gbp)

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", institution_domain: "wise.com", logo_choice: "brandfetch" } }

    assert_redirected_to institution_group_url(bundle_slug)
    assert [ @eur, @gbp ].all? { |account| account.reload.logo_brandfetch? }
    assert group.logo_brandfetch?
    assert @gbp.logo.attached?, "the stored logo is kept to switch back to, as in the account form"
    assert_nil flash[:alert]
    get institution_group_url(bundle_slug)
    assert_select "header img[src=?]", @gbp.brandfetch_logo_url
  end

  test "Brandfetch without an icon for the domain is not applied, and the flash says so" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", logo_choice: "brandfetch" } }

    assert_redirected_to institution_group_url(bundle_slug)
    assert_equal I18n.t("institution_groups.update.logo_not_applied"), flash[:alert]
    assert [ @eur, @gbp ].none? { |account| account.reload.logo_brandfetch? }
    assert_not group.logo_brandfetch?
  end

  test "the group's stored logo, which the picker offers while it shows Brandfetch, is shared with every account" do
    shared_blob = attach_logo(@eur, "profile_image.png")
    old_blob = attach_logo(@gbp)
    @eur.update!(logo_selection: :brandfetch)

    assert_no_enqueued_jobs only: AccountLogoFetchJob do
      perform_enqueued_jobs only: ActiveStorage::PurgeJob do
        patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", institution_domain: "wise.com", logo_choice: "stored" } }
      end
    end

    assert_equal [ shared_blob ] * 3, [ @eur.reload.logo.blob, @gbp.reload.logo.blob, group.logo.blob ]
    assert @eur.logo_automatic?, "the shared logo must show over Brandfetch"
    assert group.logo_automatic?
    assert_not ActiveStorage::Blob.exists?(old_blob.id), "the replaced logo nobody uses any more is purged"

    perform_enqueued_jobs only: ActiveStorage::PurgeJob do
      @eur.choose_logo("remove")
    end

    assert ActiveStorage::Blob.exists?(shared_blob.id), "removing one account's logo must keep the image the others use"
    assert_equal shared_blob, @gbp.reload.logo.blob
  end

  test "removing the icon in the settings removes the group's and every account's stored logo, purging only images nobody else uses" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    outsider = accounts(:depository)
    shared = ActiveStorage::Blob.create_and_upload!(io: file_fixture("square-placeholder.png").open, filename: "shared.png", content_type: "image/png")
    own = ActiveStorage::Blob.create_and_upload!(io: file_fixture("profile_image.png").open, filename: "own.png", content_type: "image/png")
    [ @eur, outsider ].each { |account| account.update!(logo: shared) }
    @gbp.update!(logo: own, logo_selection: :brandfetch)

    perform_enqueued_jobs only: ActiveStorage::PurgeJob do
      patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", logo_choice: "remove" } }
    end

    assert_redirected_to institution_group_url(bundle_slug)
    assert [ @eur, @gbp ].none? { |account| account.reload.logo.attached? }
    assert_not group.logo.attached?
    assert @gbp.logo_automatic?
    assert_equal shared, outsider.reload.logo.blob, "an account outside the institution keeps the image"
    assert ActiveStorage::Blob.exists?(shared.id)
    assert_not ActiveStorage::Blob.exists?(own.id), "an image no account uses any more is purged"
  end

  test "without an icon chosen nothing changes the icons, and a new domain fetches each account's as an edit would" do
    eur_blob = attach_logo(@eur)
    get institution_group_url(bundle_slug)

    assert_enqueued_jobs 2, only: AccountLogoFetchJob do
      patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise", institution_domain: "wise.de", logo_choice: "" } }
    end

    assert_equal eur_blob, @eur.reload.logo.blob
    assert_not @gbp.reload.logo.attached?
    assert_equal eur_blob, @family.institution_groups.find_by!(key: "wise|wise.de").logo.blob
  end

  test "changing one account's icon in its own form leaves the group's and its siblings' alone" do
    eur_blob = attach_logo(@eur)
    get institution_group_url(bundle_slug)
    # The account changed now comes first; the group still keeps the icon it formed with.
    @user.update!(default_account_order: "name_desc")

    patch depository_path(@gbp), params: { account: { logo: fixture_file_upload("profile_image.png", "image/png") } }

    assert_equal "profile_image.png", @gbp.reload.logo.blob.filename.to_s
    assert_equal eur_blob, @eur.reload.logo.blob
    assert_equal eur_blob, group.logo.blob
    get institution_group_url(bundle_slug)
    assert_select "header img[src=?]", @eur.stored_logo_url
  end

  test "accounts the user cannot edit are skipped, and the flash says so" do
    usd = create_account("Wise USD", @family)
    member = users(:family_member)
    { @eur => "full_control", @gbp => "full_control", usd => "read_only" }.each do |account, permission|
      account.account_shares.create!(user: member, permission: permission)
    end
    sign_in member

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "wise.com" } }

    assert_redirected_to institution_group_url(bundle_slug("wise business|wise.com"))
    assert_equal I18n.t("institution_groups.update.skipped_accounts", count: 1), flash[:alert]
    assert_equal [ "Wise Business", "Wise Business", "Wise" ], [ @eur, @gbp, usd ].map { |account| account.reload.institution_name }
    assert_equal "wise.com", usd.institution_domain
  end

  test "a failure leaves the accounts and the group as they were" do
    # A logo stored before uploads were checked cannot be given to another account.
    svg = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("<svg/>"), filename: "logo.svg", content_type: "image/svg+xml")
    ActiveStorage::Attachment.create!(name: "logo", record: @eur, blob: svg)
    get institution_group_url(bundle_slug)
    assert_equal svg, group.logo.blob, "a group forms even when its first account's icon is an old SVG"
    @eur.update!(logo_selection: :brandfetch)
    group.update!(logo_selection: :brandfetch)

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", currency: "EUR", logo_choice: "stored" } }

    assert_response :unprocessable_entity
    assert_equal [ "Wise", "Wise" ], [ @eur, @gbp ].map { |account| account.reload.institution_name }
    assert @eur.logo_brandfetch?
    assert_not @gbp.logo.attached?
    assert_equal [ "wise|wise.com", nil, "brandfetch" ], group.slice(:key, :currency, :logo_selection).values
  end

  test "an upload that is not an image is refused, and nothing takes anything" do
    gbp_blob = attach_logo(@gbp)
    get institution_group_url(bundle_slug)

    assert_no_difference -> { ActiveStorage::Attachment.count } do
      patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "wise.de",
                                                                               logo: fixture_file_upload("test.txt", "text/plain") } }
    end

    assert_response :unprocessable_entity
    assert_equal [ [ "Wise", "wise.com" ] ] * 2, [ @eur, @gbp ].map { |account| account.reload.slice(:institution_name, :institution_domain).values }
    assert_not @eur.logo.attached?
    assert_equal gbp_blob, @gbp.logo.blob
    assert_not group.logo.attached?
  end

  test "update refuses an unsupported currency" do
    patch institution_group_url(bundle_slug), params: { institution_group: { currency: "XYZ" } }
    assert_response :unprocessable_entity
    assert_nil group.currency
  end

  test "a guest's view of an institution saves no settings, and shows its first account's icon" do
    blob = attach_logo(@eur)
    guest = users(:family_member)
    guest.update!(role: "guest")
    [ @eur, @gbp ].each { |account| account.account_shares.create!(user: guest, permission: "read_only") }
    sign_in guest

    assert_no_difference -> { InstitutionGroup.count } do
      get institution_group_url(bundle_slug)
      get accounts_url
    end
    assert_response :success

    sign_in @user
    get institution_group_url(bundle_slug)
    assert_equal blob, group.logo.blob, "the owner's view forms the group, with the first account's icon"
  end

  test "settings are not editable by a guest or for another family's institution" do
    get institution_group_url(bundle_slug) # the owner's view forms the group
    guest = users(:family_member)
    guest.update!(role: "guest")
    [ @eur, @gbp ].each { |account| account.account_shares.create!(user: guest, permission: "read_only") }
    sign_in guest
    get institution_group_url(bundle_slug)
    assert_response :success
    assert_select "a[href='#{edit_institution_group_path(bundle_slug)}']", count: 0

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Taken over" } }
    assert_redirected_to accounts_url
    get logo_options_institution_group_url(bundle_slug), headers: { "Turbo-Frame" => "logo_field_account" }
    assert_redirected_to accounts_url
    assert_nil group.name
    assert_equal "Wise", @eur.reload.institution_name

    sign_in @user
    2.times { |index| create_account("Other Wise #{index}", families(:empty)) }
    @eur.update!(institution_name: "Revolut")

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Taken over" } }

    assert_response :not_found
    assert_not InstitutionGroup.exists?(name: "Taken over")
  end

  private
    def create_account(name, family, **attributes)
      family.accounts.create!(name: name, balance: 10, currency: family.currency, institution_name: "Wise", institution_domain: "wise.com",
                              accountable: Depository.new, **attributes)
    end

    def attach_logo(account, fixture = "square-placeholder.png")
      account.logo.attach(io: file_fixture(fixture).open, filename: "#{account.name}.png", content_type: "image/png")
      account.logo.blob
    end

    def group
      @family.institution_groups.find_by!(key: "wise|wise.com")
    end

    def bundle_slug(key = "wise|wise.com")
      "depository-#{Digest::MD5.hexdigest(key)[0, 12]}"
    end
end
