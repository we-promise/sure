require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
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
    @account.update!(prefer_brandfetch_logo: true)

    patch depository_path(@account), params: {
      account: { logo: fixture_file_upload("square-placeholder.png", "image/png") }
    }

    assert_redirected_to account_path(@account)
    assert @account.reload.logo.attached?
    assert_not @account.prefer_brandfetch_logo?, "an upload is shown instead of Brandfetch"
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

  test "update falls back to the automatic fetch when the chosen icon fails for a new domain" do
    Account::LogoFetcher.any_instance.expects(:fetch).returns(false)

    assert_enqueued_jobs 1, only: AccountLogoFetchJob do
      patch depository_path(@account), params: { account: { institution_domain: "krungsri.com", logo_choice: "yandex" } }
    end
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
        assert_select "button[form=?][data-action='account-logo-picker#search']", dom_id(@account, :logo_options)
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
