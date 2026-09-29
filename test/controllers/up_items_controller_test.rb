require "test_helper"

class UpItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @up_item = UpItem.create!(
      family: families(:dylan_family),
      name: "Main Up",
      access_token: "up-personal-token"
    )
  end

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
