require "test_helper"

class UpItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @up_item = UpItem.create!(family: @family, name: "Main Up", access_token: "up-personal-token")
  end

  include ProviderLinkAuthorizationTests
  provider_link_authorization_tests(
    select_url: :select_existing_account_up_items_url,
    link_url: :link_existing_account_up_items_url,
    target: ->(owner) {
      @family.accounts.create!(owner: owner, name: "Manual Checking", balance: 0, currency: "AUD",
                               accountable: Depository.create!(subtype: "checking"))
    },
    provider_account: -> {
      @up_item.up_accounts.create!(name: "Up Spending", account_id: SecureRandom.hex(6), currency: "AUD")
    },
    provider_param: :up_account_id,
    params: -> { { up_item_id: @up_item.id } },
    prepare: -> { UpItemsController.any_instance.stubs(:fetch_up_accounts_from_api).returns(nil) }
  )

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_up_item_url(@up_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "up-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @up_item.reload.syncing?
  end

  # The Accounts page's Sync button posts here too, without the panel's source.
  test "sync from the Accounts page goes back to it" do
    post sync_up_item_url(@up_item),
         headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => accounts_url }

    assert_redirected_to accounts_url
  end

  # Redirecting back to Bank sync collapses the open connection row.
  test "update from the page re-renders the panel in place" do
    patch up_item_url(@up_item),
          params: { up_item: { name: "Renamed Up", access_token: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "up-providers-panel"
    assert_includes response.body, %(id="up-providers-panel")
    assert_equal "Renamed Up", @up_item.reload.name
    assert_equal "up-personal-token", @up_item.access_token
  end

  test "invalid create from the page shows the error in the panel" do
    post up_items_url,
         params: { up_item: { name: "Second Up", access_token: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "up-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("Access token can't be blank")
  end

  # The new connection belongs in Your connections, so the page reloads.
  test "create from the page still reloads Bank sync" do
    post up_items_url,
         params: { up_item: { name: "Second Up", access_token: "another-token" } },
         as: :turbo_stream

    assert_redirected_to settings_providers_path
  end
end
