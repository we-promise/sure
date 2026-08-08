# frozen_string_literal: true

require "test_helper"

# Tests PluggyItemsController#create — the panel's credential flow (client_id +
# client_secret) and the PluggyConnect widget `item_id` flow. Unlike Plaid,
# Pluggy has no public-token exchange: the widget returns an `itemId` that is
# usable directly with the family's developer credentials and is stored verbatim
# on `PluggyItem#pluggy_item_id` (see PluggyItem::Provider#item_id). A successful
# `create` of either flow enqueues the initial sync (mirrors the
# AkahuItemsController#create pattern). SDD red-first; GREEN expectation enforced
# by T18 controller edits.
class PluggyItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    Provider::Factory.ensure_adapters_loaded
  end

  test "credential flow creates a PluggyItem and redirects to providers Connect drawer when no item id can be discovered" do
    assert_difference -> { PluggyItem.count }, 1 do
      assert_no_enqueued_jobs only: SyncJob do
        post pluggy_items_url, params: {
          pluggy_item: {
            name: "Pluggy Connection",
            client_id: "test_client_id",
            client_secret: "test_client_secret"
          }
        }
      end
    end

    assert_redirected_to connect_form_settings_providers_path(provider_key: "pluggy")

    item = PluggyItem.order(created_at: :desc).first
    assert_equal "Pluggy Connection", item.name
    assert_equal "test_client_id", item.client_id
    assert item.credentials_configured?
    assert_nil item.pluggy_item_id
  end

  # #4: Pluggy explicitly refuses listing existing connections ("not provided
  # for security reasons" per https://docs.pluggy.ai/docs/item), so a
  # PluggyItem's pluggy_item_id can NEVER be auto-discovered from the
  # credentials alone — it must be persisted from the widget/webhook/dashboard.
  # A credential-only POST (no pluggy_item_id) takes the auto-connect branch
  # (should_auto_connect?), redirects to the Connect drawer, and leaves
  # pluggy_item_id blank; the Syncer's `hydrate_item_id!` is now an intentional
  # no-op (see PluggyItem#hydrate_item_id!), so the row stays unhydrated until
  # the user completes the widget. The `assert_not respond_to?(:latest_item_id)`
  # guard is the #4 lock: it fails at load time if anyone re-adds
  # `Provider::Pluggy.latest_item_id` (the deleted helper wrapped Pluggy's
  # refused "list items" endpoint). A definition-level lock is stricter than a
  # call-level `.never` expectation, which silently passes while the method
  # stays undefined — the latter only fires if a regressed caller actually
  # invokes it.
  test "credential flow does not eagerly call the Pluggy API on create even when an item id is discoverable" do
    assert_not Provider::Pluggy.respond_to?(:latest_item_id)

    assert_difference -> { PluggyItem.count }, 1 do
      assert_no_enqueued_jobs only: SyncJob do
        post pluggy_items_url, params: {
          pluggy_item: {
            name: "Pluggy Connection",
            client_id: "test_client_id",
            client_secret: "test_client_secret"
          }
        }
      end
    end

    assert_redirected_to connect_form_settings_providers_path(provider_key: "pluggy")

    item = PluggyItem.order(created_at: :desc).first
    assert item.credentials_configured?
    assert_nil item.pluggy_item_id
  end

  test "widget item_id flow stores the returned itemId verbatim with no token exchange and enqueues the sync" do
    # The PluggyConnect widget (T19) POSTs the itemId it returned on success
    # alongside the developer credentials. There is no Plaid-style
    # public_token exchange — the itemId is stored directly on
    # `pluggy_item_id` and is immediately usable to fetch accounts.
    assert_difference -> { PluggyItem.count }, 1 do
      assert_enqueued_with(job: SyncJob) do
        post pluggy_items_url, params: {
          pluggy_item: {
            client_id: "widget_client_id",
            client_secret: "widget_client_secret",
            pluggy_item_id: "widget-returned-item-id"
          }
        }
      end
    end

    assert_redirected_to settings_providers_path

    item = PluggyItem.order(created_at: :desc).first
    assert_equal "widget-returned-item-id", item.pluggy_item_id
  end

  test "create re-renders the providers panel when validation fails" do
    assert_no_difference -> { PluggyItem.count } do
      post pluggy_items_url, params: {
        pluggy_item: { name: "Bad" }
      }
    end

    # Missing client_id/client_secret fails presence validations; the controller
    # redirects back to the providers page carrying a 422 (not a 3xx), so
    # assert_redirected_to (which expects 3xx) does not apply.
    assert_response :unprocessable_entity
    assert_match %r{settings/providers}, response.headers["Location"]
  end

  test "new redirects to providers connect drawer" do
    get new_pluggy_item_url

    assert_redirected_to connect_form_settings_providers_path(provider_key: "pluggy")
  end

  test "sync blocks when pluggy_item_id is missing" do
    item = PluggyItem.create!(
      family: users(:family_admin).family,
      name: "Pluggy Without Item",
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      pluggy_item_id: nil
    )

    assert_no_enqueued_jobs only: SyncJob do
      post sync_pluggy_item_url(item)
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("pluggy_items.sync.missing_item_id"), flash[:alert]
  end

  test "sync enqueues when pluggy_item_id is present" do
    item = PluggyItem.create!(
      family: users(:family_admin).family,
      name: "Pluggy Connected",
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      pluggy_item_id: "item-123"
    )

    assert_enqueued_with(job: SyncJob) do
      post sync_pluggy_item_url(item)
    end

    assert_redirected_to accounts_path
  end

  test "preload_accounts prefers connected item when multiple Pluggy items exist" do
    family = users(:family_admin).family

    PluggyItem.create!(
      family: family,
      name: "Older Credentials",
      client_id: "old_client",
      client_secret: "old_secret",
      pluggy_item_id: nil,
      created_at: 2.days.ago,
      updated_at: 2.days.ago
    )

    connected = PluggyItem.create!(
      family: family,
      name: "Connected Item",
      client_id: "new_client",
      client_secret: "new_secret",
      pluggy_item_id: "item-connected",
      created_at: 1.day.ago,
      updated_at: 1.day.ago
    )

    assert_enqueued_with(job: SyncJob) do
      get preload_accounts_pluggy_items_url(accountable_type: "Depository", return_to: accounts_path)
    end

    assert_redirected_to select_accounts_pluggy_items_path(accountable_type: "Depository", return_to: accounts_path)
  end

  test "update turbo-stream renders the success notice inline inside the drawer panel, not the occluded notification-tray" do
    # The Pluggy Connect drawer (DS::Dialog → native <dialog>.showModal()) renders
    # _pluggy_panel inside <turbo-frame id="pluggy-connect-form">, separate from the
    # main /settings/providers page wrapper (#pluggy-providers-panel, produced by
    # _connection_row.html.erb). A native <dialog> opened via showModal() paints in
    # the browser top layer, ABOVE the base layout's z-50 #notification-tray, so a
    # notice appended to #notification-tray is invisible while the drawer is open.
    # The fix renders the notice INSIDE the panel (#pluggy-panel-notice) and refreshes
    # BOTH panel wrappers so the panel visibly updates in either render context.
    PluggyItem::Provider.any_instance.stubs(:connect_token).returns("fake_token")

    item = PluggyItem.create!(
      family: users(:family_admin).family,
      name: "Pluggy Connected",
      client_id: "old_client",
      client_secret: "old_secret",
      pluggy_item_id: "item-123"
    )

    patch pluggy_item_url(item),
          params: { pluggy_item: { client_id: "new_client", client_secret: "new_secret" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html", "Turbo-Frame" => "drawer" }

    assert_response :success

    body = response.body
    # BOTH wrappers refresh so the panel updates whether the form was submitted from
    # the main /settings/providers page (<turbo-frame id="pluggy-providers-panel">, via
    # replace — existing behavior) or the Pluggy Connect drawer (<turbo-frame
    # id="pluggy-connect-form">, via update — preserves the <turbo-frame target="_top">
    # wrapper). Each id is unique to its context, so the stream targeting the absent
    # context is a silent no-op.
    assert_includes body, 'target="pluggy-providers-panel"'
    assert_includes body, 'target="pluggy-connect-form"'
    # The notice is BAKED INTO the re-rendered panel (#pluggy-panel-notice) — not
    # appended to the global #notification-tray, which the drawer's <dialog> top-layer
    # backdrop occludes. `replace`/`update` re-render the partial with the notice, so
    # the inline slot appears inside whichever frame the user submitted from.
    assert_includes body, 'id="pluggy-panel-notice"'
    assert_includes body, I18n.t("pluggy_items.update.success")
    refute_includes body, 'target="notification-tray"'

    # Credentials persisted to the existing row (UPDATE — no new record, no overwrite
    # of pluggy_item_id, just the user-supplied client_id/client_secret).
    assert_equal "new_client", item.reload.client_id
    assert_equal "new_secret", item.reload.client_secret
  end
end
