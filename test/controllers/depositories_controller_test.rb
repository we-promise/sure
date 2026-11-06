require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  # The provider link's visibility and the controller's gate are two
  # expressions of one rule, and they disagreed. ConnectorAuthorizable requires
  # `member_connectable? && Current.user&.member?`; the selector asked only
  # `admin? || member_connectable`, so a GUEST was shown the link and refused
  # on submit -- a control that looks broken rather than one that is absent.
  #
  # One user, one family, one variable: the role changes between the two
  # requests and nothing else does, so a difference can only be the role.
  test "a member-connectable provider is offered to a member and withheld from a guest" do
    config = {
      key: "test_provider",
      name: "Test Provider",
      member_connectable: true,
      new_account_path: ->(_accountable_type, _return_to) { "/test-provider/new" }
    }
    Provider::Factory.stubs(:connection_configs_for_account_type).returns([ config ])

    sign_in user = users(:family_member)

    get new_depository_url(step: "method_select")
    assert_response :success
    assert_select "a[href='/test-provider/new']", { minimum: 1 },
                  "a member may connect this provider and must be offered it"

    user.update!(role: :guest)

    get new_depository_url(step: "method_select")
    assert_response :success
    assert_select "a[href='/test-provider/new']", { count: 0 },
                  "a guest was offered a link require_connector_create! refuses"
  end

  test "create falls back to the stored return_to when no form param is present" do
    get new_account_path(return_to: transactions_path) # StoreLocation captures it into the session

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "Return To Checking", currency: "USD", balance: 100, accountable_type: "Depository" }
      }
    end

    assert_redirected_to transactions_path
  end

  test "create prefers the form return_to over the session value" do
    get new_account_path(return_to: transactions_path) # session return_to

    post depositories_path, params: {
      account: { name: "Form RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: budgets_path }
    }

    assert_redirected_to budgets_path
  end

  test "create ignores an external return_to (open-redirect guard)" do
    post depositories_path, params: {
      account: { name: "Evil RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: "https://evil.example/phish" }
    }

    created = Account.order(:created_at).last
    assert_redirected_to account_path(created) # not the external URL
  end

  test "create persists a manually entered iban" do
    post depositories_path, params: {
      account: { name: "IBAN Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "de89 3704 0044 0532 0130 00" }
    }

    created = Account.order(:created_at).last
    assert_equal "DE89370400440532013000", created.iban # pipelock:ignore IBAN
  end

  test "create does not choke on a stray remove_iban param" do
    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "No Iban Checking", currency: "USD", balance: 100, accountable_type: "Depository", remove_iban: "1" }
      }
    end

    created = Account.order(:created_at).last
    assert_nil created.iban
  end

  test "create re-renders the form instead of a 500 when the iban is already used in the family" do
    @account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    assert_no_difference -> { Account.count } do
      post depositories_path, params: {
        account: { name: "Duplicate IBAN Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "DE89370400440532013000" } # pipelock:ignore IBAN
      }
    end

    assert_response :unprocessable_entity
  end

  test "create re-renders the form instead of a 500 on a raw unique-index race" do
    # Simulates two concurrent requests both passing the Rails uniqueness
    # validation before either commits -- the second one hits the raw DB
    # constraint instead, surfacing as RecordNotUnique rather than the
    # RecordInvalid the previous test covers.
    Account.any_instance.stubs(:save!).raises(
      ActiveRecord::RecordNotUnique.new('duplicate key value violates unique constraint "index_accounts_on_family_id_and_iban_and_currency"')
    )

    assert_no_difference -> { Account.count } do
      post depositories_path, params: {
        account: { name: "Race Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "DE89370400440532013000" } # pipelock:ignore IBAN
      }
    end

    assert_response :unprocessable_entity
  end

  test "update re-renders the form instead of a 500 on a raw unique-index race" do
    linked_account = accounts(:connected)
    Account.any_instance.stubs(:update).raises(
      ActiveRecord::RecordNotUnique.new('duplicate key value violates unique constraint "index_accounts_on_family_id_and_iban_and_currency"')
    )

    patch depository_path(linked_account), params: {
      account: { iban: "DE89370400440532013000" } # pipelock:ignore IBAN
    }

    assert_response :unprocessable_entity
  end

  test "update rolls back a balance change when the iban update fails in the same request" do
    linked_account = accounts(:connected)
    other_account = accounts(:depository)
    other_account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN
    original_balance = linked_account.balance

    patch depository_path(linked_account), params: {
      account: { balance: original_balance + 100, iban: "DE89370400440532013000" } # pipelock:ignore IBAN
    }

    assert_response :unprocessable_entity
    assert_equal original_balance, linked_account.reload.balance,
      "the balance change must not persist when the same request's iban update fails"
  end

  test "update persists a manually entered iban through the shared update action" do
    linked_account = accounts(:connected)

    patch depository_path(linked_account), params: {
      account: { iban: "AT611904300234573201" } # pipelock:ignore IBAN
    }

    assert_equal "AT611904300234573201", linked_account.reload.iban # pipelock:ignore IBAN
  end

  test "update with a blank iban field leaves the stored iban unchanged" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    patch depository_path(linked_account), params: {
      account: { name: "Renamed", iban: "" }
    }

    assert_equal "AT611904300234573201", linked_account.reload.iban # pipelock:ignore IBAN
    assert_equal "Renamed", linked_account.reload.name
  end

  test "update with an iban that normalizes to nothing leaves the stored iban unchanged" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    patch depository_path(linked_account), params: {
      account: { iban: " - " }
    }

    assert_equal "AT611904300234573201", linked_account.reload.iban # pipelock:ignore IBAN
  end

  test "a failed update still offers to remove the stored iban" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    patch depository_path(linked_account), params: {
      account: { name: "", remove_iban: "1" }
    }

    assert_response :unprocessable_entity
    assert_select "input[type=checkbox][name='account[remove_iban]']", 1
  end

  test "create re-renders the form with a stray remove_iban when the account must be rebuilt" do
    # A failure whose record is neither the account nor tied to one makes
    # #create rebuild the account from the submitted params.
    Account.any_instance.stubs(:lock_saved_attributes!).raises(ActiveRecord::RecordInvalid.new(Depository.new))

    post depositories_path, params: {
      account: { name: "Rebuilt Checking", currency: "USD", balance: 100, accountable_type: "Depository", remove_iban: "1" }
    }

    assert_response :unprocessable_entity
  end

  test "update with remove_iban checked clears the stored iban even with a blank field" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    patch depository_path(linked_account), params: {
      account: { iban: "", remove_iban: "1" }
    }

    assert_nil linked_account.reload.iban
  end

  test "update persists enable_category_matcher through the shared update action" do
    linked_account = accounts(:connected)
    assert linked_account.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "0" }
    }

    refute linked_account.reload.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "1" }
    }

    assert linked_account.reload.enable_category_matcher?
  end

  test "edit form never renders the stored iban" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    get edit_account_url(linked_account)

    assert_response :success
    refute_includes response.body, "AT611904300234573201" # pipelock:ignore IBAN
    assert_select "input[type=checkbox][name='account[remove_iban]'][aria-labelledby='account_remove_iban_label']", 1
    assert_select "#account_remove_iban_label", text: I18n.t("accounts.form.iban_remove_label")
  end

  test "iban field masks keystrokes like a password field and signals a stored value" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    get edit_account_url(linked_account)

    assert_response :success
    # type=password, not type=text: typed input must be masked as you go,
    # not just withheld from the initial render.
    assert_select "input[type=password][name='account[iban]']", 1
    # The placeholder alone ("IBAN on file...") was easy to miss -- a fixed
    # run of bullets makes a stored value visually obvious at a glance.
    assert_select "input[name='account[iban]'][placeholder^=?]", "••••"
  end

  test "edit form does not render a remove_iban toggle when no iban is stored" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: nil)

    get edit_account_url(linked_account)

    assert_response :success
    assert_select "input[type=checkbox][name='account[remove_iban]']", 0
  end

  test "edit form renders category matcher toggle only for accounts that support it" do
    get edit_account_url(accounts(:connected))
    assert_response :success
    assert_select "input[type=checkbox][name='account[enable_category_matcher]']", 1

    get edit_account_url(accounts(:depository))
    assert_response :success
    assert_select "input[name='account[enable_category_matcher]']", 0
  end

  # --- member-owned connections (issue #3579) ------------------------------

  test "a member sees only member-connectable providers in the method selector" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(stub("plaid"))
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(true)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_member)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_plaid_item_path(region: "us", accountable_type: "Depository"), count: 1
    # SimpleFIN is tenant-wide, so it must not be offered to a member even
    # when it is configured.
    assert_select "a[href*=?]", "simplefin", count: 0
  end

  test "an admin still sees every configured provider in the method selector" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(stub("plaid"))
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(true)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_admin)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_plaid_item_path(region: "us", accountable_type: "Depository"), count: 1
  end

  test "a member is offered manual entry even with no connectable providers" do
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(false)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_member)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_depository_path, count: 1
  end

  test "edit form explains the institution domain and links to Brandfetch settings when the key is missing" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    with_self_hosting do
      get edit_account_url(@account)
    end

    assert_response :success
    assert_select "[data-testid=institution-domain-hint]", text: /Brandfetch/
    assert_select "[data-testid=institution-domain-hint] a[href=?]", settings_hosting_path
  end

  test "edit form only explains the institution domain when Brandfetch is configured" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")

    get edit_account_url(@account)

    assert_response :success
    assert_select "[data-testid=institution-domain-hint]", text: I18n.t("accounts.form.institution_domain_hint")
    assert_select "[data-testid=institution-domain-hint] a", 0
  end

  test "update uploads a logo that replaces Brandfetch" do
    @account.update!(logo_selection: "brandfetch")

    patch depository_path(@account), params: {
      account: { logo: fixture_file_upload("square-placeholder.png", "image/png") }
    }

    assert_redirected_to account_path(@account)
    assert @account.reload.logo.attached?
    assert @account.logo_automatic?, "an upload is shown instead of Brandfetch"
  end

  test "update rejects a logo that is not an image" do
    patch depository_path(@account), params: {
      account: { logo: fixture_file_upload("test.txt", "text/plain") }
    }

    assert_response :unprocessable_entity
    assert_not @account.reload.logo.attached?
  end

  test "update applies the icon chosen in the form" do
    Account::LogoFetcher.any_instance.expects(:fetch).with(source: "appstore:123").returns(true)

    patch depository_path(@account), params: { account: { name: "Renamed", logo_choice: "appstore:123" } }

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
    assert_nil flash[:alert]
  end

  test "create with an institution domain fetches an icon for the new account" do
    assert_enqueued_with(job: AccountLogoFetchJob) do
      post depositories_path, params: {
        account: { name: "Krungsri savings", balance: 100, currency: "USD", accountable_type: "Depository",
                   institution_domain: "https://www.krungsri.com/", accountable_attributes: { subtype: "savings" } }
      }
    end

    assert_equal "krungsri.com", Account.order(:created_at).last.read_attribute(:institution_domain)
  end

  test "create applies the icon picked in the new account form instead of fetching one" do
    Account::LogoFetcher.any_instance.expects(:fetch).with(source: "appstore:1").returns(true)

    assert_no_enqueued_jobs only: AccountLogoFetchJob do
      post depositories_path, params: { account: { name: "Krungsri savings", balance: 100, currency: "USD", accountable_type: "Depository",
                   institution_domain: "krungsri.com", accountable_attributes: { subtype: "savings" } }.merge(logo_choice: "appstore:1") }
    end

    assert_redirected_to account_path(Account.order(:created_at).last)
    assert_nil flash[:alert]
  end

  test "create attaches an icon uploaded in the new account form" do
    post depositories_path, params: { account: { name: "Krungsri savings", balance: 100, currency: "USD", accountable_type: "Depository",
                   institution_domain: "krungsri.com", accountable_attributes: { subtype: "savings" } }.merge(logo: fixture_file_upload("square-placeholder.png", "image/png")) }

    assert Account.order(:created_at).last.logo.attached?
  end

  test "new account form offers the picker without an account id" do
    get new_depository_path

    assert_response :success
    assert_select "[data-controller=account-logo-picker] button[form=?]", "logo_options_account"
    assert_select "form#logo_options_account[action=?][data-turbo-frame=?]", logo_options_accounts_path, "logo_field_account"
  end

  test "update with a chosen icon skips the automatic fetch for a new domain" do
    Account::LogoFetcher.any_instance.expects(:fetch).with(source: "yandex").returns(true)

    assert_no_enqueued_jobs only: AccountLogoFetchJob do
      patch depository_path(@account), params: { account: { institution_domain: "krungsri.com", logo_choice: "yandex" } }
    end

    assert_redirected_to account_path(@account)
  end

  test "update without a chosen icon fetches one for a new domain" do
    assert_enqueued_with(job: AccountLogoFetchJob) do
      patch depository_path(@account), params: { account: { institution_domain: "krungsri.com" } }
    end
  end

  test "update saves the account when the chosen icon cannot be downloaded" do
    Account::LogoFetcher.any_instance.expects(:fetch).returns(false)

    patch depository_path(@account), params: { account: { name: "Renamed", logo_choice: "yandex" } }

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
    assert_equal I18n.t("accounts.update.logo_not_applied"), flash[:alert]
  end

  test "update falls back to the paced automatic fetch when the chosen icon fails for a new domain" do
    Account::LogoFetcher.any_instance.expects(:fetch).returns(false)
    AccountLogoFetchJob.expects(:perform_paced).once

    patch depository_path(@account), params: { account: { institution_domain: "krungsri.com", logo_choice: "yandex" } }

    assert_redirected_to account_path(@account)
  end

  test "update lets an upload win over an icon chosen in the same form" do
    Account::LogoFetcher.any_instance.expects(:fetch).never

    patch depository_path(@account), params: {
      account: { logo: fixture_file_upload("square-placeholder.png", "image/png"), logo_choice: "yandex" }
    }

    assert_redirected_to account_path(@account)
    assert @account.reload.logo.attached?
  end

  test "update leaves the icon alone when the form fails" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")

    patch depository_path(@account), params: { account: { name: "", logo_choice: "remove" } }

    assert_response :unprocessable_entity
    assert @account.reload.logo.attached?
  end

  test "edit form previews the icon and keeps the choice for saving" do
    @account.update!(institution_domain: "tbank.ru")
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")

    get edit_account_url(@account)

    assert_response :success
    frame = dom_id(@account, :logo_field)
    assert_select "[data-controller=account-logo-picker]" do
      assert_select "turbo-frame##{frame}" do
        assert_select "button[form=?][data-action='account-logo-picker#search'][data-turbo=true]", dom_id(@account, :logo_options)
        assert_select "button[type=button][data-action='account-logo-picker#remove']"
        assert_select "template[data-account-logo-picker-target=fallback]"
      end
      assert_select "input[type=hidden][name='account[logo_choice]'][data-account-logo-picker-target=choice]"
      assert_select "input[type=file][name='account[logo]'][data-account-logo-picker-target=file]"
    end
    assert_select "form[id=?][action=?][method=get][data-turbo-frame=?]", dom_id(@account, :logo_options), logo_options_account_path(@account), frame do
      assert_select "input[type=hidden][name=institution_domain][value=?]", "tbank.ru"
      assert_select "input[type=hidden][name=institution_name]"
    end
  end

  test "edit form offers the picker before a domain is saved" do
    @account.update!(institution_domain: nil)

    get edit_account_url(@account)

    assert_select "button[form=?]", dom_id(@account, :logo_options)
  end
end
