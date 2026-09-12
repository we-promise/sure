require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

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

  # Regression for the broken manual icon: the form submits a multipart logo
  # and logo_source=manual (set by the logo-source controller on file select).
  # The uploaded blob must actually be served, not just attached — the bytes
  # used to be lost to a dropped after-commit upload, leaving a 404ing icon.
  test "create with a manually uploaded logo serves the uploaded file" do
    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "Manual Logo Checking",
          currency: "USD",
          balance: 100,
          accountable_type: "Depository",
          subtype: "checking",
          logo: fixture_file_upload("square-placeholder.png", "image/png"),
          logo_source: "manual"
        }
      }
    end

    account = @user.family.accounts.find_by!(name: "Manual Logo Checking")
    assert account.logo_source_manual?
    assert account.logo.attached?

    # The blob URL redirects to the storage service URL; follow it to prove
    # the actual bytes are served (a missing file 404s here).
    get account.logo_url
    follow_redirect!
    assert_response :success, "the manually uploaded logo URL must not be broken"
    assert_equal account.logo.blob.download, response.body
  end

  # Same flow when the logo-source JS never ran and the hidden field still
  # carries "auto": the upload itself must still be stored correctly.
  test "create with an uploaded logo and an auto source still stores the file" do
    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "Auto Logo Checking",
          currency: "USD",
          balance: 100,
          accountable_type: "Depository",
          subtype: "checking",
          logo: fixture_file_upload("square-placeholder.png", "image/png"),
          logo_source: "auto"
        }
      }
    end

    account = @user.family.accounts.find_by!(name: "Auto Logo Checking")
    assert account.logo.attached?

    get account.logo_url
    follow_redirect!
    assert_response :success, "the uploaded logo URL must not be broken even when the source stayed auto"
  end

  # The form previews a stored logo; the broken-image fallback wiring must be
  # present so a stored-but-broken logo never renders as a broken <img>.
  test "edit form renders the broken-image fallback wiring for a stored logo" do
    @account.logo.attach(
      io: StringIO.new("some-logo"),
      filename: "logo.png",
      content_type: "image/png"
    )

    get edit_account_url(@account)
    assert_response :success
    assert_select "[data-controller='image-fallback']"
    assert_select "img[data-image-fallback-target='image']"
    assert_select "[data-image-fallback-target='fallback']"
  end
end
