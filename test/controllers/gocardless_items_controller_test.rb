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

  test "blank secrets keep stored credentials and updates reach other connections" do
    other = @family.gocardless_items.create!(name: "Second bank", secret_id: "old-id", secret_key: "old-key")
    patch gocardless_item_url(@item), params: { gocardless_item: { secret_id: "", secret_key: "" } }
    assert_equal "test-id", @item.reload.secret_id

    patch gocardless_item_url(@item), params: { gocardless_item: { secret_id: "new-id", secret_key: "new-key" } }
    assert_equal "new-id", other.reload.secret_id
    assert_equal "new-key", other.secret_key
  end

  test "setup form creates accounts from the submitted per-account types" do
    depository = @item.gocardless_accounts.create!(name: "Current", currency: "GBP", gocardless_account_id: "acc-1", current_balance: 10)
    skipped = @item.gocardless_accounts.create!(name: "Savings", currency: "GBP", gocardless_account_id: "acc-2", current_balance: 20)

    assert_difference -> { @family.accounts.count }, 1 do
      post complete_account_setup_gocardless_item_url(@item), params: {
        accounts: {
          depository.id => { account_type: "depository" },
          skipped.id => { account_type: "skip" }
        }
      }
    end

    assert_redirected_to accounts_url
    assert depository.reload.account_provider.present?
    assert skipped.reload.account_provider.blank?
  end

  test "setup form renders one type select per unlinked account" do
    account = @item.gocardless_accounts.create!(name: "Current", currency: "GBP", gocardless_account_id: "acc-1")

    get setup_accounts_gocardless_item_url(@item)

    assert_response :success
    assert_select "select[name='accounts[#{account.id}][account_type]']"
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

  test "reconnect renews consent and swaps the requisition on callback" do
    @item.update!(institution_id: "TEST_BANK", institution_name: "Test bank", status: :requires_update)
    stub_new_consent
    reference = nil
    Provider::Gocardless.any_instance.expects(:create_requisition).with { |args| reference = args[:reference] }
                        .returns(id: "requisition-2", status: "CR", link: "https://bankaccountdata.gocardless.com/psd2/start/x")

    post reauthorize_gocardless_item_url(@item)
    assert_redirected_to "https://bankaccountdata.gocardless.com/psd2/start/x"
    assert_not_equal @item.id, reference

    Provider::Gocardless.any_instance.stubs(:get_requisition).with(requisition_id: "requisition-2").returns(status: "LN", accounts: [ "account-1" ])
    Provider::Gocardless.any_instance.expects(:delete_requisition).with(requisition_id: "requisition-1")
    GocardlessItem.any_instance.expects(:sync_later).once

    get callback_gocardless_items_url(ref: reference)

    @item.reload
    assert_redirected_to accounts_path
    assert_equal "requisition-2", @item.requisition_id
    assert @item.good?
    assert_in_delta 730.days.from_now, @item.consent_expires_at, 1.minute
  end

  test "an abandoned reconnect keeps the current requisition" do
    @item.update!(institution_id: "TEST_BANK")
    stub_new_consent
    reference = nil
    Provider::Gocardless.any_instance.stubs(:create_requisition).with { |args| reference = args[:reference] }
                        .returns(id: "requisition-2", status: "CR", link: "https://bankaccountdata.gocardless.com/psd2/start/x")
    post reauthorize_gocardless_item_url(@item)

    Provider::Gocardless.any_instance.stubs(:get_requisition).with(requisition_id: "requisition-2").returns(status: "RJ", accounts: [])
    Provider::Gocardless.any_instance.expects(:delete_requisition).with(requisition_id: "requisition-2")
    get callback_gocardless_items_url(ref: reference)

    assert_equal "requisition-1", @item.reload.requisition_id
  end

  test "a reconnect reference only completes in the session that started it" do
    @item.update!(institution_id: "TEST_BANK")
    stub_new_consent
    reference = nil
    Provider::Gocardless.any_instance.stubs(:create_requisition).with { |args| reference = args[:reference] }
                        .returns(id: "requisition-2", status: "CR", link: "https://bankaccountdata.gocardless.com/psd2/start/x")
    post reauthorize_gocardless_item_url(@item)

    reset!
    sign_in users(:family_admin)
    Provider::Gocardless.any_instance.expects(:get_requisition).never

    get callback_gocardless_items_url(ref: reference)

    assert_redirected_to accounts_path
    assert_equal "requisition-1", @item.reload.requisition_id
  end

  test "deleting a connection revokes its requisition" do
    Provider::Gocardless.any_instance.expects(:delete_requisition).with(requisition_id: "requisition-1")
    delete gocardless_item_url(@item)
    assert @item.reload.scheduled_for_deletion?
  end

  private

    def stub_new_consent
      Provider::Gocardless.any_instance.stubs(:get_institution).returns(id: "TEST_BANK", name: "Test bank", transaction_total_days: "730", max_access_valid_for_days: "730")
      Provider::Gocardless.any_instance.stubs(:create_agreement).returns(id: "agreement-2", access_valid_for_days: 730)
    end
end
