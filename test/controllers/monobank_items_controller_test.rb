require "test_helper"

class MonobankItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @monobank_item = MonobankItem.create!(
      family: @family,
      name: "Main Monobank",
      access_token: "monobank-personal-token"
    )
    @monobank_account = @monobank_item.monobank_accounts.create!(
      name: "Black card ·1234",
      account_id: "acc_1",
      currency: "UAH",
      account_kind: "card",
      account_type: "black"
    )
  end

  test "create saves the connection and starts a sync" do
    # The setup-wide stub allows zero calls, so the enqueue is asserted explicitly here:
    # a regression that stops kicking off the first sync would otherwise pass.
    SyncJob.expects(:perform_later).with { |sync| sync.syncable.is_a?(MonobankItem) }.once

    assert_difference "MonobankItem.count", 1 do
      post monobank_items_url, params: {
        monobank_item: { name: "Second Monobank", access_token: "another-token" }
      }
    end

    assert_redirected_to settings_providers_path

    created = MonobankItem.order(:created_at).last
    assert_equal "another-token", created.access_token
    assert_equal 1, created.syncs.count
  end

  test "update keeps the existing token when the field is left blank" do
    patch monobank_item_url(@monobank_item), params: {
      monobank_item: { name: "Renamed", access_token: "" }
    }

    @monobank_item.reload
    assert_equal "Renamed", @monobank_item.name
    assert_equal "monobank-personal-token", @monobank_item.access_token
  end

  # Redirecting back to Bank sync collapses the open connection row.
  test "update from the page re-renders the panel in place" do
    patch monobank_item_url(@monobank_item),
          params: { monobank_item: { name: "Renamed Monobank", access_token: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "monobank-providers-panel"
    assert_includes response.body, %(id="monobank-providers-panel")
    assert_equal "Renamed Monobank", @monobank_item.reload.name
  end

  test "invalid create from the page shows the error in the panel" do
    post monobank_items_url,
         params: { monobank_item: { name: "Second Monobank", access_token: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "monobank-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("Access token can't be blank")
  end

  # The new connection belongs in Your connections, so the page reloads.
  test "create from the page still reloads Bank sync" do
    post monobank_items_url,
         params: { monobank_item: { name: "Second Monobank", access_token: "another-token" } },
         as: :turbo_stream

    assert_redirected_to settings_providers_path
  end

  test "setup_accounts renders the pending accounts with a preselected type" do
    MonobankItemsController.any_instance.stubs(:fetch_monobank_accounts_from_api).returns(nil)

    get setup_accounts_monobank_item_url(@monobank_item)
    assert_response :success

    select = css_select("select[name='account_types[#{@monobank_account.id}]']").first
    assert select, "expected scoped account_types[#{@monobank_account.id}] select"
    selected_option = css_select("select[name='account_types[#{@monobank_account.id}]'] option[selected='selected']").first
    assert_equal "Depository", selected_option["value"]
  end

  test "complete_account_setup creates a savings account for a jar" do
    jar = @monobank_item.monobank_accounts.create!(
      name: "На тепловізор", account_id: "jar_1", currency: "UAH", account_kind: "jar", account_type: "jar"
    )

    assert_difference [ "Account.count", "AccountProvider.count" ], 1 do
      post complete_account_setup_monobank_item_url(@monobank_item), params: {
        account_types: { jar.id.to_s => "Depository", @monobank_account.id.to_s => "skip" }
      }
    end

    assert_redirected_to accounts_path
    created_account = jar.reload.current_account
    assert_equal "Depository", created_account.accountable_type
    assert_equal "savings", created_account.accountable.subtype
    assert @monobank_account.reload.ignored?, "a skipped account stops resurfacing as needing setup"
  end

  # Monobank allows one client-info request per minute, so the very first setup screen
  # regularly collides with the sync that just ran. The screen must still offer the
  # accounts already on file instead of blocking on a refresh failure.
  test "setup_accounts still offers the stored accounts when the refresh fails" do
    MonobankItemsController.any_instance
      .stubs(:fetch_monobank_accounts_from_api)
      .returns(I18n.t("monobank_items.setup_accounts.api_error"))

    get setup_accounts_monobank_item_url(@monobank_item)

    assert_response :success
    assert_select "select[name='account_types[#{@monobank_account.id}]']", 1
    assert_select "button[type=submit][disabled]", false, "the refresh failure must not block setup"
    assert_select "body", text: /#{Regexp.escape(I18n.t("monobank_items.setup_accounts.api_error"))}/
  end

  test "select_accounts still offers the stored accounts when the refresh fails" do
    MonobankItemsController.any_instance
      .stubs(:fetch_monobank_accounts_from_api)
      .returns(I18n.t("monobank_items.setup_accounts.api_error"))

    get select_accounts_monobank_items_url, params: {
      monobank_item_id: @monobank_item.id, accountable_type: "Depository"
    }

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", @monobank_account.id
  end

  test "select_accounts renders the unlinked accounts" do
    MonobankItemsController.any_instance.stubs(:fetch_monobank_accounts_from_api).returns(nil)

    get select_accounts_monobank_items_url, params: {
      monobank_item_id: @monobank_item.id, accountable_type: "Depository"
    }

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", @monobank_account.id
  end

  test "select_accounts rejects unsafe return paths" do
    MonobankItemsController.any_instance.stubs(:fetch_monobank_accounts_from_api).returns(nil)

    unsafe_return_paths.each do |return_to|
      get select_accounts_monobank_items_url, params: {
        monobank_item_id: @monobank_item.id,
        accountable_type: "Depository",
        return_to: return_to
      }

      assert_response :success
      assert_select %(input[name="return_to"]) do |fields|
        assert fields.first["value"].blank?, "expected #{return_to.inspect} to be rejected"
      end
    end
  end

  test "sync enqueues a sync for the connection" do
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @monobank_item }.once

    post sync_monobank_item_url(@monobank_item)

    assert_redirected_to accounts_path
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_monobank_item_url(@monobank_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "monobank-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @monobank_item.reload.syncing?
  end

  test "destroy schedules the connection for deletion" do
    DestroyJob.expects(:perform_later).with(@monobank_item).once

    delete monobank_item_url(@monobank_item)

    assert_redirected_to settings_providers_path
    assert @monobank_item.reload.scheduled_for_deletion?
  end

  private

    def unsafe_return_paths
      [
        "https://evil.example/accounts",
        "http://evil.example/accounts",
        "//evil.example/accounts",
        "\\evil.example/accounts",
        "/\\evil.example/accounts",
        "/%2fevil.example/accounts",
        "/%2Fevil.example/accounts",
        "/%5cevil.example/accounts",
        "/%5Cevil.example/accounts",
        "/\naccounts",
        "/ accounts"
      ]
    end
end
