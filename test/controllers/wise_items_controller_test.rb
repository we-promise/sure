# frozen_string_literal: true

require "test_helper"

class WiseItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
    @wise_item = wise_items(:one)

    @valid_profiles = [
      { "id" => "99999999", "type" => "personal", "details" => { "firstName" => "Jane", "lastName" => "Doe" } }
    ]
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_wise_item_url(@wise_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "wise-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @wise_item.reload.syncing?
  end

  # The Accounts page's Sync button posts here too, without the panel's source.
  test "sync from the Accounts page goes back to it" do
    post sync_wise_item_url(@wise_item),
         headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => accounts_url }

    assert_redirected_to accounts_url
  end

  # Linking a balance to a Sure account

  # A sync in flight has already picked the accounts it processes, and
  # sync_later only reuses it, so the new account used to stay empty until the
  # next sync.
  test "a balance set up while the connection syncs is processed straight away" do
    wise_account = wise_accounts(:checking)
    wise_account.update!(raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                         raw_transactions_payload: [
                           { "id" => 4711, "targetAccount" => 1234, "sourceCurrency" => "EUR", "targetCurrency" => "EUR",
                             "sourceValue" => 25.0, "targetValue" => 25.0, "status" => "outgoing_payment_sent",
                             "created" => 2.days.ago.utc.strftime("%Y-%m-%d %H:%M:%S") }
                         ])
    running = @wise_item.syncs.create!
    running.start!
    @wise_item.process_accounts # the balances linked when the running sync began (none)

    perform_enqueued_jobs(only: WiseItem::ProcessLinkedAccountJob) do
      post complete_account_setup_wise_item_url(@wise_item), params: { wise_account_id: wise_account.id }
    end

    account = wise_account.reload.account
    assert_equal [ "wise_transfer_4711" ], account.entries.where(source: "wise").pluck(:external_id)
    assert_equal [ running.id ], @wise_item.syncs.pluck(:id)
    assert account.syncs.exists?, "the account's balances are recalculated"
  end

  test "a balance linked from the account form while the connection syncs gets its own processing" do
    @wise_item.syncs.create!.start!
    wise_account = wise_accounts(:checking)

    assert_no_difference "@wise_item.syncs.count" do
      assert_enqueued_with(job: WiseItem::ProcessLinkedAccountJob, args: [ wise_account ]) do
        post link_accounts_wise_items_url, params: { wise_account_id: wise_account.id }
      end
    end
    assert wise_account.reload.account.present?
  end

  test "link_existing_account links a cash account in the balance's currency and syncs the connection" do
    account = manual_account(currency: "EUR")
    wise_account = wise_accounts(:checking)

    assert_difference "@wise_item.syncs.count", 1 do
      post link_existing_account_wise_items_url, params: { account_id: account.id, wise_account_id: wise_account.id }
    end

    assert_redirected_to accounts_path
    assert_equal wise_account, account.reload.provider_account_for("WiseAccount")
    assert_no_enqueued_jobs only: WiseItem::ProcessLinkedAccountJob
  end

  test "link_existing_account while the connection syncs gets the balance its own processing" do
    @wise_item.syncs.create!.start!
    account = manual_account(currency: "EUR")
    wise_account = wise_accounts(:checking)

    assert_no_difference "@wise_item.syncs.count" do
      assert_enqueued_with(job: WiseItem::ProcessLinkedAccountJob, args: [ wise_account ]) do
        post link_existing_account_wise_items_url, params: { account_id: account.id, wise_account_id: wise_account.id }
      end
    end
    assert_equal wise_account, account.reload.provider_account_for("WiseAccount")
  end

  # The rule is meant for an account another provider feeds; for another Wise
  # balance AccountProvider's own one-link-per-provider validation already
  # refuses it (with another message).
  test "link_existing_account refuses an account already linked to a provider" do
    fed_by_lunch_flow = manual_account(currency: "EUR")
    AccountProvider.create!(account: fed_by_lunch_flow, provider: lunchflow_accounts(:investment_account))
    linked_to_jar = Account.create!(family: @family, name: "Manual Jar", accountable: Depository.new(subtype: "savings"),
                                    balance: 0, currency: "EUR")
    AccountProvider.create!(account: linked_to_jar, provider: wise_accounts(:jar))

    [ fed_by_lunch_flow, linked_to_jar ].each do |account|
      assert_link_existing_account_refused account, I18n.t("wise_items.link_existing_account.account_already_linked")
    end
    assert_nil fed_by_lunch_flow.reload.provider_account_for("WiseAccount")
  end

  test "link_existing_account refuses an account that is not a cash account" do
    card = Account.create!(family: @family, name: "EUR card", accountable: CreditCard.new, balance: 0, currency: "EUR")

    assert_link_existing_account_refused card, I18n.t("wise_items.link_existing_account.unsupported_account_type")
  end

  # A sync overwrites the account's currency with the balance's, which would
  # leave the account's own entries in another currency.
  test "link_existing_account refuses an account in another currency than the balance" do
    account = manual_account(currency: "USD")

    assert_link_existing_account_refused account, I18n.t("wise_items.link_existing_account.currency_mismatch",
                                                         account_currency: "USD", balance_currency: "EUR")
  end

  # Every balance in another currency would be refused, so the dialog offers
  # only those in the account's, and none here.
  test "select_existing_account offers only the balances in the account's currency" do
    { "EUR" => [ "Jar", "Wise EUR" ], "USD" => [] }.each do |currency, offered|
      account = manual_account(currency: currency)

      get select_existing_account_wise_items_url(account_id: account.id, wise_item_id: @wise_item.id)

      assert_response :success
      assert_equal offered, wise_items(:one).wise_accounts.unlinked.where(id: css_select("input[name='wise_account_id']").map { |input| input["value"] })
                                                            .pluck(:name).sort
      assert_includes response.body, I18n.t("wise_items.select_existing_account.no_accounts_found") if offered.empty?
    end
  end

  test "link_existing_account goes back where it came from when it refuses a balance" do
    account = manual_account(currency: "USD")

    post link_existing_account_wise_items_url, params: { account_id: account.id, wise_account_id: wise_accounts(:checking).id,
                                                         return_to: "/accounts/#{account.id}" }

    assert_redirected_to "/accounts/#{account.id}"
  end

  # create redirects to select_profiles (Turbo requires a redirect from a standard
  # form submission) — the encrypted token travels via the session, not the response body.

  test "create redirects to select_profiles and keeps raw token out of the session" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)

    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    assert_redirected_to select_profiles_wise_items_path
    assert_nil session[:wise_pending_token], "raw API token must not be stored in the session"
    assert session[:wise_pending_encrypted_token].present?

    follow_redirect!
    assert_select "input[name='encrypted_pending_token']"
  end

  test "create stores an encrypted token that round-trips to the original value" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)

    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }
    follow_redirect!

    encrypted = css_select("input[name='encrypted_pending_token']").first["value"]
    assert encrypted.present?, "hidden encrypted_pending_token field must be present"

    key = Rails.application.key_generator.generate_key("wise_pending_token", 32)
    decrypted = ActiveSupport::MessageEncryptor.new(key).decrypt_and_verify(encrypted)
    assert_equal "live_token_abc", decrypted
  end

  test "create redirects to providers on blank token" do
    post wise_items_url, params: { wise_item: { token: "" } }
    assert_redirected_to settings_providers_path
    assert_nil session[:wise_pending_token]
  end

  test "create from the drawer shows a blank token error in the panel" do
    post wise_items_url,
         params: { wise_item: { token: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "wise-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("Token can't be blank")
  end

  test "create redirects to providers when Wise API rejects the token" do
    Provider::Wise.any_instance.stubs(:get_profiles).raises(
      Provider::Wise::WiseError.new("unauthorized", :unauthorized)
    )

    post wise_items_url, params: { wise_item: { token: "bad_token" } }
    assert_redirected_to settings_providers_path
    assert_nil session[:wise_pending_token]
  end

  # link_profiles reads the encrypted token from the session (set by create) —
  # the client no longer needs to (and cannot) supply or tamper with it via params.

  test "link_profiles creates WiseItems using the session-held encrypted token" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    assert_difference "WiseItem.count", 1 do
      post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }
    end

    assert_redirected_to settings_providers_path
    assert_equal "live_token_abc", @family.wise_items.find_by!(profile_id: "99999999").token
    assert_nil session[:wise_pending_profiles]
    assert_nil session[:wise_pending_encrypted_token]
  end

  test "link_profiles applies the pending import_all_history setting to created items" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc", import_all_history: "1" } }

    assert_difference "WiseItem.count", 1 do
      post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }
    end

    assert @family.wise_items.find_by!(profile_id: "99999999").import_all_history?
    assert_nil session[:wise_pending_import_all_history]
  end

  test "link_profiles defaults import_all_history to false when not requested" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }

    assert_not @family.wise_items.find_by!(profile_id: "99999999").import_all_history?
  end

  test "link_profiles applies import_all_history to every created profile" do
    profiles = [
      { "id" => "99999999", "type" => "personal", "details" => { "firstName" => "Jane", "lastName" => "Doe" } },
      { "id" => "88888888", "type" => "business", "details" => { "name" => "Acme" } }
    ]
    Provider::Wise.any_instance.stubs(:get_profiles).returns(profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc", import_all_history: "1" } }

    assert_difference "WiseItem.count", 2 do
      post link_profiles_wise_items_url, params: { profile_ids: [ "99999999", "88888888" ] }
    end

    assert @family.wise_items.find_by!(profile_id: "99999999").import_all_history?
    assert @family.wise_items.find_by!(profile_id: "88888888").import_all_history?
    assert_nil session[:wise_pending_import_all_history]
  end

  test "link_profiles redirects to providers when there is no pending session" do
    post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }

    assert_redirected_to settings_providers_path
  end

  test "generate_sca_keypair stores a keypair on the item" do
    WiseItem.any_instance.stubs(:sca_encryption_available?).returns(true)

    assert_nil @wise_item.sca_private_key

    post generate_sca_keypair_wise_item_url(@wise_item)

    assert_redirected_to accounts_path
    assert @wise_item.reload.sca_configured?
  end

  test "generate_sca_keypair from the page shows the new public key in place" do
    WiseItem.any_instance.stubs(:sca_encryption_available?).returns(true)

    post generate_sca_keypair_wise_item_url(@wise_item),
         as: :turbo_stream

    assert_turbo_stream action: "replace", target: "wise-providers-panel"
    assert_includes response.body, %(id="wise-providers-panel")
    assert_includes response.body, @wise_item.reload.sca_public_key.lines.second.strip
  end

  test "update from the page re-renders the panel in place instead of leaving for accounts" do
    patch wise_item_url(@wise_item),
          params: { wise_item: { name: "Renamed Wise" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "wise-providers-panel"
    assert_equal "Renamed Wise", @wise_item.reload.name
  end

  test "generate_sca_keypair replaces a previously generated keypair" do
    WiseItem.any_instance.stubs(:sca_encryption_available?).returns(true)

    @wise_item.generate_sca_keypair!
    previous_key = @wise_item.sca_private_key

    post generate_sca_keypair_wise_item_url(@wise_item)

    assert_not_equal previous_key, @wise_item.reload.sca_private_key
  end

  test "generate_sca_keypair reports an error rather than storing a key in the clear" do
    WiseItem.stubs(:encryption_ready?).returns(false)

    post generate_sca_keypair_wise_item_url(@wise_item)

    assert_nil @wise_item.reload.sca_private_key
  end

  test "link_profiles redirects to providers when the session token cannot be decrypted" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    session[:wise_pending_encrypted_token] = "corrupted_garbage_value"

    post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }

    assert_redirected_to settings_providers_path
  end

  test "select accounts leaves the Add Account modal for Settings at the top level" do
    families(:dylan_family).wise_items.update_all(scheduled_for_deletion: true)

    get select_accounts_wise_items_url, headers: { "Turbo-Frame" => "modal" }

    # A redirect would be followed inside the frame and the flash lost.
    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("wise_items.select_accounts.no_connection"), flash[:alert]
  end

  test "select accounts redirects to Settings outside a turbo frame" do
    families(:dylan_family).wise_items.update_all(scheduled_for_deletion: true)

    get select_accounts_wise_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("wise_items.select_accounts.no_connection"), flash[:alert]
  end

  private

    def manual_account(currency:)
      Account.create!(family: @family, name: "Manual #{currency}", accountable: Depository.new(subtype: "checking"),
                      balance: 0, currency: currency)
    end

    def assert_link_existing_account_refused(account, message)
      assert_no_difference [ "AccountProvider.count", "@wise_item.syncs.count" ] do
        assert_no_enqueued_jobs only: WiseItem::ProcessLinkedAccountJob do
          post link_existing_account_wise_items_url, params: { account_id: account.id, wise_account_id: wise_accounts(:checking).id }
        end
      end

      assert_redirected_to accounts_path
      assert_equal message, flash[:alert]
    end
end
