require "test_helper"

class GocardlessItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = @family.gocardless_items.create!(name: "Test bank", secret_id: "test-id", secret_key: "test-key", requisition_id: "requisition-1")
  end

  test "bank picker renders the modal and institutions" do
    Provider::Gocardless.any_instance.stubs(:get_institutions).returns([ { id: "TEST_BANK", name: "Test bank", transaction_total_days: 730 } ])
    get new_gocardless_item_url, headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "button", text: /Test bank/
  end

  test "members cannot create connections" do
    sign_in users(:family_member)
    assert_no_difference "GocardlessItem.count" do
      post gocardless_items_url, params: { gocardless_item: { secret_id: "id", secret_key: "key" } }, as: :json
    end
    assert_response :forbidden
  end

  test "cannot access another family's connection" do
    other = families(:empty).gocardless_items.create!(name: "Other bank", secret_id: "id", secret_key: "key")
    patch gocardless_item_url(other), params: { gocardless_item: { name: "Changed" } }
    assert_response :not_found
    assert_equal "Other bank", other.reload.name
  end

  test "linked callback enqueues sync for the family connection" do
    Provider::Gocardless.any_instance.stubs(:get_requisition).with(requisition_id: "requisition-1").returns(status: "LN", accounts: [ "account-1" ])
    GocardlessItem.any_instance.expects(:sync_later).once
    get callback_gocardless_items_url(ref: @item.id)
    assert_redirected_to accounts_url
    assert_equal "LN", @item.reload.requisition_status
    assert @item.pending_account_setup?
  end

  test "callback rejects another family's reference" do
    other = families(:empty).gocardless_items.create!(name: "Other bank", secret_id: "id", secret_key: "key")
    Provider::Gocardless.any_instance.expects(:get_requisition).never
    get callback_gocardless_items_url(ref: other.id)
    assert_redirected_to accounts_url
    assert_nil other.reload.requisition_status
  end

  test "connect handles an API failure with a valid return route" do
    Provider::Gocardless.any_instance.stubs(:get_institution).raises(Provider::Gocardless::GocardlessError.new("Unavailable"))
    post connect_gocardless_items_url, params: { institution_id: "TEST_BANK" }
    assert_redirected_to new_gocardless_item_url
    assert_equal "Unavailable", flash[:alert]
  end

  test "consent redirects require HTTPS and a trusted host" do
    controller = GocardlessItemsController.new
    assert controller.send(:valid_gocardless_redirect_url?, "https://bankaccountdata.gocardless.com/consent")
    assert_not controller.send(:valid_gocardless_redirect_url?, "http://bankaccountdata.gocardless.com/consent")
    assert_not controller.send(:valid_gocardless_redirect_url?, "https://gocardless.com.attacker.example/consent")
  end
  test "a member sees only shared accounts on a GoCardless card" do
    shared, private_account = [ "Shared GoCardless account", "Private GoCardless account" ].map.with_index do |name, index|
      account = @family.accounts.create!(name: name, balance: 10, currency: "GBP", accountable: Depository.new, owner: users(:family_admin))
      account.account_shares.destroy_all
      row = @item.gocardless_accounts.create!(name: name, currency: "GBP", gocardless_account_id: "account-#{index}")
      row.ensure_account_provider!(account)
      account
    end
    shared.account_shares.create!(user: users(:family_member), permission: "read_only")
    sign_in users(:family_member)

    get accounts_url

    assert_response :success
    assert_includes response.body, shared.name
    assert_not_includes response.body, private_account.name
  end

  test "bank sync settings include configured GoCardless in your connections" do
    get settings_providers_url
    assert_response :success
    assert_select "details#gocardless-connection summary h3", text: "GoCardless"
    assert_select "div#gocardless-providers-panel", count: 1
  end

  test "bank sync settings offer GoCardless when unconfigured" do
    @item.destroy!
    get settings_providers_url
    assert_response :success
    assert_select "details#gocardless-connection", count: 0
    assert_select "a[href=?]", connect_form_settings_providers_path(provider_key: "gocardless")
  end
end
