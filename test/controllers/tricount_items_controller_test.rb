# frozen_string_literal: true

require "test_helper"
require_relative "../support/tricount_test_helper"

class TricountItemsControllerTest < ActionDispatch::IntegrationTest
  include TricountTestHelper

  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
  end

  def followed_item
    item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    tricount_account = item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)
    [ item, tricount_account ]
  end

  test "following a tricount link stores its token and syncs" do
    assert_difference -> { @family.tricount_items.count }, 1 do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://tricount.com/#{SHARING_TOKEN}" } }
    end

    item = @family.tricount_items.order(:created_at).last
    assert_equal [ SHARING_TOKEN ], item.sharing_token_list
    assert_equal [ "Tricount", "tricount.com", "https://tricount.com" ], [ item.institution_name, item.institution_domain, item.institution_url ]
    assert item.syncing?
  end

  # One connection per family follows all its links: a second create (another
  # settings tab, a resubmit) adds to it.
  test "following a link again adds it to the existing connection" do
    post tricount_items_url, params: { tricount_item: { sharing_links: "https://tricount.com/#{SHARING_TOKEN}" } }

    assert_no_difference -> { @family.tricount_items.count } do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://tricount.com/tSecondOne42" } }
    end

    assert_equal [ SHARING_TOKEN, "tSecondOne42" ], @family.tricount_items.sole.sharing_token_list
  end

  test "a link that is not a tricount link is refused" do
    assert_no_difference -> { @family.tricount_items.count } do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://example.com/" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "border-destructive-subtle", "shown with DS::Alert"
    assert_includes response.body, I18n.t("tricount_items.create.invalid_links")
  end

  test "adding a link keeps the tricounts already followed" do
    item, = followed_item

    patch tricount_item_url(item), params: { tricount_item: { sharing_links: "tSecondOne42" } }

    assert_equal [ SHARING_TOKEN, "tSecondOne42" ], item.reload.sharing_token_list
  end

  # Another request (a second settings tab) added a link after this one loaded
  # the connection; merging under the row lock keeps both.
  test "adding a link keeps one another request added meanwhile" do
    item, = followed_item
    stale = TricountItem.find(item.id)
    item.update_column(:sharing_tokens, [ SHARING_TOKEN, "tOtherTab77" ].join("\n"))
    lookup = mock
    lookup.stubs(:find).returns(stale)
    lookup.stubs(:active).returns(TricountItem.where(id: item.id))
    Family.any_instance.stubs(:tricount_items).returns(lookup)

    patch tricount_item_url(item), params: { tricount_item: { sharing_links: "tSecondOne42" } }

    assert_equal [ SHARING_TOKEN, "tOtherTab77", "tSecondOne42" ], item.reload.sharing_token_list
  end

  # The panel's single action is the form builder's submit, as on the other
  # providers' panels.
  test "the provider panel submits with the form's own action" do
    item, = followed_item

    patch tricount_item_url(item), params: { tricount_item: { sharing_links: "tSecondOne42" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    panel = response.body[/id="tricount-providers-panel".*/m]
    assert panel, "the panel was not rendered"
    assert_equal 1, panel.scan(/<button[^>]*type="submit"[^>]*data-turbo-submits-with/).size
  end

  # Every action on the connection is an admin's; a member shown the card for
  # an account shared with them isn't offered them.
  test "the connection's actions are shown to admins only" do
    item, tricount_account = followed_item
    tricount_account.assign_member!(ME)
    account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    tricount_account.ensure_account_provider!(account)
    account.account_shares.find_or_create_by!(user: users(:family_member)) { |share| share.permission = "read_only" }
    sync_link = "a[href='#{sync_tricount_item_path(item)}'], form[action='#{sync_tricount_item_path(item)}']"

    get accounts_url
    assert_select sync_link, minimum: 1

    sign_in users(:family_member)
    get accounts_url
    assert_response :success
    assert_includes response.body, item.name
    assert_select sync_link, count: 0
    assert_select "form[action='#{tricount_item_path(item)}']", count: 0
  end

  # Setting up its other tricounts is an admin's too.
  test "the setup link for a connection's other tricounts is shown to admins only" do
    item, tricount_account = followed_item
    tricount_account.assign_member!(ME)
    account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    tricount_account.ensure_account_provider!(account)
    account.account_shares.find_or_create_by!(user: users(:family_member)) { |share| share.permission = "read_only" }
    item.tricount_accounts.new.upsert_from_tricount!(tricount_registry.merge("uuid" => "second-tricount", "id" => 2))
    setup_link = "a[href='#{setup_accounts_tricount_item_path(item)}']"

    get accounts_url
    assert_select setup_link, minimum: 1

    sign_in users(:family_member)
    get accounts_url
    assert_response :success
    assert_includes response.body, item.name
    assert_select setup_link, count: 0
  end

  # A connection being removed keeps its card, marked as such, until its
  # accounts are unlinked.
  test "the accounts page shows a connection pending deletion" do
    item, tricount_account = followed_item
    tricount_account.assign_member!(ME)
    tricount_account.ensure_account_provider!(@family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new))
    item.update!(scheduled_for_deletion: true)

    get accounts_url

    assert_response :success
    assert_includes response.body, I18n.t("tricount_items.tricount_item.deletion_in_progress")
  end

  # The family's default sharing applies, as for accounts created elsewhere.
  test "accounts created at setup are shared with the family when it shares by default" do
    @family.update!(default_account_sharing: "shared")
    item, tricount_account = followed_item

    post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }

    account = tricount_account.reload.current_account
    assert_includes account.account_shares.pluck(:user_id), users(:family_member).id
  end

  test "setting up a tricount creates a cash account following the chosen member" do
    item, tricount_account = followed_item

    post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }

    account = tricount_account.reload.current_account
    assert_redirected_to accounts_url
    assert_equal [ "Weekend trip", "Depository", BigDecimal("-20"), "EUR" ], [ account.name, account.accountable_type, account.balance, account.currency ]
    assert_equal ME, tricount_account.member_uuid
    assert_equal [ "Tricount", "tricount.com" ], [ account.read_attribute(:institution_name), account.read_attribute(:institution_domain) ]
  end

  test "accounts can be named with a Tricount prefix, and the choice is remembered" do
    item, tricount_account = followed_item

    post complete_account_setup_tricount_item_url(item),
      params: { prefix_account_names: "1", accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }

    assert_equal "tricount: Weekend trip", tricount_account.reload.current_account.name
    assert item.reload.prefix_account_names?
  end

  test "a tricount can't be set up without choosing a member" do
    item, tricount_account = followed_item

    assert_no_difference -> { Account.count } do
      post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: "" } } }
    end
    assert_redirected_to setup_accounts_tricount_item_url(item)
    assert_equal I18n.t("tricount_items.complete_account_setup.member_required"), flash[:alert]
  end

  test "the setup page lists each tricount with its members to choose from" do
    item, = followed_item

    get setup_accounts_tricount_item_url(item)

    assert_response :success
    assert_select "div.bg-container-inset", text: I18n.t("tricount_items.setup_accounts.instructions")
    assert_select "a[href='#{accounts_path}'][data-turbo-frame='_top']", text: I18n.t("tricount_items.setup_accounts.cancel")
    tricount_account = item.tricount_accounts.sole
    assert_select "input[type=hidden][name='accounts[#{tricount_account.id}][member_uuid]']"
    assert_select "[role=option][data-value='#{ME}']", text: "Alex"
    assert_select "[role=option][data-value='#{KIM}']", text: "Kim"
  end

  # Nothing pushes the imported tricounts into an open setup dialog, so while
  # the first sync runs it offers a refresh, as the other providers' do.
  # Another submission links the tricount after this one looked it up; this
  # one must see that link and skip it, not create a second account or fail
  # on the link (and log that failure for support).
  test "a tricount linked by a concurrent setup gets no second account" do
    item, tricount_account = followed_item
    other = @family.accounts.create!(name: "Other trip", balance: 0, currency: "EUR", accountable: Depository.new)
    stale = TricountAccount.find(tricount_account.id)
    stale.account_provider
    TricountAccount.find(tricount_account.id).tap { |account| account.assign_member!(SAM) }.ensure_account_provider!(other)
    lookup = mock
    lookup.stubs(:find_by).returns(stale)
    TricountItem.any_instance.stubs(:unlinked_tricount_accounts).returns(lookup)

    assert_no_difference [ -> { @family.accounts.count }, -> { DebugLogEntry.where(provider_key: "tricount").count } ] do
      post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }
    end

    assert_equal [ other, SAM ], [ tricount_account.reload.current_account, tricount_account.member_uuid ]
  end

  test "an account that can't be created during setup is logged for support" do
    item, tricount_account = followed_item
    TricountAccount.any_instance.stubs(:ensure_account_provider!).raises(ActiveRecord::RecordInvalid.new(AccountProvider.new))

    assert_difference -> { DebugLogEntry.where(provider_key: "tricount", level: "error").count }, 1 do
      post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }
    end

    assert_redirected_to setup_accounts_tricount_item_url(item)
    assert_equal tricount_account.id, DebugLogEntry.where(provider_key: "tricount").order(:created_at).last.metadata["tricount_account_id"]
  end

  test "the accounts page offers the tricounts still to set up with a design-system link" do
    item, tricount_account = followed_item
    tricount_account.assign_member!(ME)
    tricount_account.ensure_account_provider!(@family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new))
    item.tricount_accounts.new.upsert_from_tricount!(tricount_registry.merge("uuid" => "second-uuid", "title" => "Ski week"))

    get accounts_url

    assert_response :success
    assert_select "a.text-link[href='#{setup_accounts_tricount_item_path(item)}'][data-turbo-frame='modal']"
  end

  test "the setup page offers a refresh while the first sync runs" do
    item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    item.sync_later

    get setup_accounts_tricount_item_url(item)

    assert_response :success
    assert_select "a[href='#{setup_accounts_tricount_item_path(item)}']", text: I18n.t("tricount_items.setup_accounts.refresh")
  end

  test "linking an existing cash account follows the chosen member" do
    item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }

    assert_redirected_to account_url(account)
    assert_equal [ account, SAM ], [ tricount_account.reload.current_account, tricount_account.member_uuid ]
    assert_equal "tricount.com", account.reload.read_attribute(:institution_domain)
  end

  test "the link dialog offers each tricount's members to choose from" do
    _item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)

    get select_existing_account_tricount_items_url(account_id: account.id)

    assert_response :success
    # Design system: the notice as a DS::Note, a default-size submit, and a
    # Cancel that leaves the modal frame.
    assert_select "div.bg-container-inset", text: /Trip/
    assert_select "button[type=submit].px-3.py-2", text: I18n.t("tricount_items.select_existing_account.link_button")
    assert_select "a[href='#{account_path(account)}'][data-turbo-frame='_top']", text: I18n.t("tricount_items.select_existing_account.cancel_button")
    assert_select "form input[type=hidden][name=member_uuid][id='#{ActionView::RecordIdentifier.dom_id(tricount_account, :existing)}_member_uuid']"
    assert_select "[role=option][data-value='#{SAM}']", text: "Sam"
  end

  test "with no tricount to link, the dialog points to the provider settings" do
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)
    @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)

    get select_existing_account_tricount_items_url(account_id: account.id)

    assert_response :success
    assert_select "a[href='#{settings_providers_path}'][data-turbo-frame='_top']", text: I18n.t("tricount_items.select_existing_account.settings_link")
  end

  test "linking submits outside the dialog's frame, so the account page reloads" do
    followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)

    get select_existing_account_tricount_items_url(account_id: account.id)

    assert_response :success
    assert_select "form[action='#{link_existing_account_tricount_items_path}'][data-turbo-frame='_top']"
  end

  # Family scoping alone lets an admin reach a co-member's account; with the
  # shares cleared the admin holds no permission on it at all.
  test "an account the admin can't manage can't be linked" do
    _item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new, owner: users(:family_member))
    account.account_shares.destroy_all

    get select_existing_account_tricount_items_url(account_id: account.id)
    assert_redirected_to accounts_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }
    assert_redirected_to accounts_url
    assert_nil tricount_account.reload.current_account
  end

  # Another provider already writes this account's balance and transactions;
  # Tricount as a second writer would overwrite them.
  test "an account another provider is linked to can't be linked" do
    _item, tricount_account = followed_item
    account = accounts(:connected)
    assert account.linked?

    get select_existing_account_tricount_items_url(account_id: account.id)
    assert_equal I18n.t("tricount_items.select_existing_account.account_already_linked"), flash[:alert]

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }

    assert_redirected_to account_url(account)
    assert_equal I18n.t("tricount_items.link_existing_account.account_already_linked"), flash[:alert]
    assert_nil tricount_account.reload.current_account
    assert_nil tricount_account.member_uuid
  end

  # The sync would switch the account to the tricount's currency, leaving its
  # history in another.
  test "an account in another currency can't be linked" do
    _item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "USD", accountable: Depository.new)

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }

    assert_redirected_to account_url(account)
    assert_equal I18n.t("tricount_items.link_existing_account.currency_mismatch", currency: "EUR"), flash[:alert]
    assert_nil tricount_account.reload.current_account
  end

  # A sync changed the tricount's currency after this request checked it; the
  # check is made again under the locks (which reload), so the account isn't
  # linked to a tricount it can't follow.
  test "a tricount whose currency changed meanwhile isn't linked" do
    _item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)
    stale = TricountAccount.find(tricount_account.id)
    tricount_account.update_column(:currency, "USD")
    lookup = mock
    lookup.stubs(:find).returns(stale)
    TricountItem.any_instance.stubs(:tricount_accounts).returns(lookup)

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }

    assert_redirected_to account_url(account)
    assert_equal I18n.t("tricount_items.link_existing_account.currency_mismatch", currency: "USD"), flash[:alert]
    assert_nil tricount_account.reload.current_account
  end

  # Another request links the tricount after this one found it unlinked; this
  # one must see that link rather than fail on the unique index.
  test "a tricount linked by a concurrent request is reported as linked" do
    _item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)
    other = @family.accounts.create!(name: "Other trip", balance: 0, currency: "EUR", accountable: Depository.new)
    supported = Provider::TricountAdapter.supported_account_types
    Provider::TricountAdapter.stubs(:supported_account_types).with do
      TricountAccount.find(tricount_account.id).ensure_account_provider!(other) if other.account_providers.none?
      true
    end.returns(supported)

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }

    assert_redirected_to account_url(account)
    assert_equal I18n.t("tricount_items.link_existing_account.provider_account_already_linked"), flash[:alert]
    assert_equal other, tricount_account.reload.current_account
  end

  test "only an admin can follow a tricount" do
    sign_in users(:family_member)

    assert_no_difference -> { @family.tricount_items.count } do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://tricount.com/#{SHARING_TOKEN}" } }
    end
    assert_redirected_to accounts_url
  end
end
