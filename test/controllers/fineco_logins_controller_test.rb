require "test_helper"

class FinecoLoginsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class RuntimeDouble
    PortfolioResult = Struct.new(:payload, :rotated_gsessionid, :account_number, :dossier_identity)

    attr_reader :capture_callback, :identity, :capture_enabled
    attr_accessor :state, :stop_state

    def initialize
      @id = "flow_abc123"
      @state = :awaiting_login
    end

    def start(identity:, on_capture:, authorized:, capture_enabled:)
      raise "not authorized" unless authorized.call(identity)

      @identity = identity.stringify_keys
      @capture_callback = on_capture
      @capture_enabled = capture_enabled
      @state = capture_enabled ? :awaiting_login : :setup_verification_required
      { id: @id, state: @state, expires_at: 20.minutes.from_now }
    end

    def status(identity:, id:, authorized:)
      validate_identity!(identity, id, authorized)
      { id: @id, state: state, expires_at: 20.minutes.from_now }
    end

    def stop(identity:, id:, reason:, authorized:)
      validate_identity!(identity, id, authorized)
      @state = stop_state || :stopped
      { id: @id, state: @state }
    end

    def capture(identity:, session:, cancelled: nil)
      capture_callback.call(identity: identity, session: session, cancelled: cancelled)
    end

    private

      def validate_identity!(identity, id, authorized)
        raise "not authorized" unless authorized.call(identity)
        raise "wrong flow" unless id == @id
        raise "wrong identity" unless identity.stringify_keys == @identity
      end
  end

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @session_id = @user.sessions.order(:created_at).last.id.to_s
    @runtime = RuntimeDouble.new
    FinecoLoginsController.any_instance.stubs(:browser_runtime).returns(@runtime)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
  end

  teardown do
    Current.reset
  end

  test "login page explains preview scope and uses a separate manual login browser" do
    with_fineco_access do
      get fineco_login_path

      assert_response :success
      assert_select "input[type=password]", count: 0
      assert_select "[data-fineco-login-target=viewer]"
      assert_select "[data-fineco-login-stream-path-value='/fineco_login/stream']"
      assert_includes response.body, I18n.t("fineco_logins.show.bank_session_authority")
      assert_not_includes response.body, "read-only Fineco access"
      assert_includes response.body, I18n.t("fineco_logins.show.read_only")
      assert_includes response.body, I18n.t("fineco_logins.show.manual_login_hint")
      assert_includes response.headers["Cache-Control"], "no-store"
    end
  end

  test "login page reports that a paused item requires reconnection" do
    FinecoItem.create!(
      family: @user.family,
      owner: @user,
      gsessionid: nil,
      account_index: "2",
      dossier_index: "4",
      captured_at: Time.current,
      bank_account_number: "fineco-test-account",
      dossier_identity: Digest::SHA256.hexdigest("fineco-test-dossier"),
      status: "requires_update",
      last_sync_error_code: "disconnected"
    )

    with_fineco_access do
      get fineco_login_path
    end

    assert_response :success
    assert_select "p[data-fineco-login-target=status]", text: I18n.t("fineco_logins.show.status_expired")
  end

  test "login page explains when identity verification is not ready for import" do
    Provider::Fineco.stubs(:verified_identity_contract?).returns(false)

    with_fineco_access do
      get fineco_login_path
    end

    assert_response :success
    assert_includes response.body, I18n.t("fineco_logins.show.setup_verification_required")
    assert_select "p[data-fineco-login-target=status]", text: I18n.t("fineco_logins.show.status_setup_verification_required")
    assert_select "button[data-action='fineco-login#start']", count: 1
  end

  test "managed hosting cannot access Fineco login" do
    with_env_overrides(FINECO_BROWSER_ENABLED: "true") do
      get fineco_login_path
    end

    assert_response :not_found
  end

  test "preview access is required" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    with_fineco_access do
      get fineco_login_path
    end

    assert_redirected_to root_path
  end

  test "non-admin users cannot open Fineco login" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    with_fineco_access do
      get fineco_login_path
    end

    assert_redirected_to accounts_path
  end

  test "impersonated sessions cannot open Fineco login" do
    impersonation = ImpersonationSession.create!(
      impersonator: users(:sure_support_staff),
      impersonated: @user,
      status: :in_progress
    )
    @user.sessions.find(@session_id).update!(active_impersonator_session: impersonation)

    with_fineco_access do
      get fineco_login_path
    end

    assert_response :forbidden
  end

  test "start returns only an opaque flow locator and binds all three identity fields" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    assert_response :accepted
    body = response_json
    assert_equal %w[expires_at flow_id state], body.keys.sort
    assert_equal "flow_abc123", body.fetch("flow_id")
    assert_equal "awaiting_login", body.fetch("state")
    assert_equal @user.id.to_s, @runtime.identity.fetch("user_id")
    assert_equal @user.family_id.to_s, @runtime.identity.fetch("family_id")
    assert_equal @session_id, @runtime.identity.fetch("session_id")
    assert_not_includes response.body, "gsessionid"
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "start uses the verified identity capability and ignores a request override" do
    Provider::Fineco.stubs(:verified_identity_contract?).returns(false)

    with_fineco_access do
      post start_fineco_login_path, params: { capture_enabled: "true" }, headers: json_headers
    end

    assert_response :accepted
    assert_equal false, @runtime.capture_enabled
    assert_equal "setup_verification_required", response_json.fetch("state")
    assert_includes response.body, "setup_verification_required"
    assert_not FinecoItem.exists?(family: @user.family, owner: @user)
  end

  test "start fails closed when explicit Active Record encryption is unavailable" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    assert_response :service_unavailable
    assert_equal "encryption_unavailable", response_json.fetch("error")
    assert_nil @runtime.identity
  end

  test "start fails closed when browser runtime is missing" do
    FinecoLoginsController.any_instance.stubs(:browser_runtime).returns(nil)

    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    assert_response :service_unavailable
    assert_equal "browser_runtime_unavailable", response_json.fetch("error")
    assert_nil @runtime.identity
  end

  test "start requires a valid CSRF token" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    assert_response :unprocessable_content
    assert_nil @runtime.identity
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "status requires the initiating browser session and exposes only safe state" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    flow_id = response_json.fetch("flow_id")

    sign_in @user
    with_fineco_access do
      get status_fineco_login_path, params: { id: flow_id }, headers: json_headers
    end

    assert_response :not_found
    assert_not_includes response.body, "gsessionid"
  end

  test "another family admin cannot reuse a Fineco flow locator" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    flow_id = response_json.fetch("flow_id")
    other_admin = users(:empty)
    other_admin.update!(preferences: (other_admin.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other_admin

    with_fineco_access do
      get status_fineco_login_path, params: { id: flow_id }, headers: json_headers
    end

    assert_response :not_found
    assert_not_includes response.body, "gsessionid"
  end

  test "status reports sanitized expiry state" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    flow_id = response_json.fetch("flow_id")
    @runtime.state = :expired

    with_fineco_access do
      get status_fineco_login_path, params: { id: flow_id }, headers: json_headers
    end

    assert_response :success
    assert_equal %w[expires_at flow_id state], response_json.keys.sort
    assert_equal flow_id, response_json.fetch("flow_id")
    assert_equal "expired", response_json.fetch("state")
    assert Time.iso8601(response_json.fetch("expires_at"))
    assert_not_includes response.body, "gsessionid"
  end

  test "stop exposes a sanitized transient stopping state" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    flow_id = response_json.fetch("flow_id")
    @runtime.stop_state = :stopping

    with_fineco_access do
      delete stop_fineco_login_path, params: { id: flow_id }, headers: json_headers
    end

    assert_response :success
    assert_equal({ "state" => "stopping" }, response_json)
  end

  test "stop is bound to the initiating session and returns no credential data" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    flow_id = response_json.fetch("flow_id")

    with_fineco_access do
      delete stop_fineco_login_path, params: { id: flow_id }, headers: json_headers
    end

    assert_response :success
    assert_equal({ "state" => "stopped" }, response_json)
    assert_not_includes response.body, "gsessionid"
  end

  test "capture verifies the selected portfolio before encrypted persistence" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    result = RuntimeDouble::PortfolioResult.new(
      portfolio_payload,
      "rotated-session-cookie",
      "SYNTHETIC-ACCOUNT-2",
      Digest::SHA256.hexdigest("synthetic-dossier")
    )
    client = mock("Fineco verification client")
    client.expects(:fetch_portfolio_summary).returns(result)
    Provider::Fineco.expects(:new).with(
      gsessionid: "captured-session-cookie",
      account_index: "2",
      dossier_index: "4"
    ).returns(client)

    captured = nil
    with_fineco_access do
      captured = @runtime.capture(
        identity: @runtime.identity,
        session: {
          gsessionid: "captured-session-cookie",
          account_index: "2",
          dossier_index: "4",
          captured_at: Time.current
        }
      )
    end

    assert captured
    item = FinecoItem.find_by!(family: @user.family, owner: @user)
    assert_equal "rotated-session-cookie", item.gsessionid
    assert_equal "2", item.account_index
    assert_equal "4", item.dossier_index
    assert_equal "SYNTHETIC-ACCOUNT-2", item.bank_account_number
    assert_equal Digest::SHA256.hexdigest("synthetic-dossier"), item.dossier_identity
    assert_equal BigDecimal("0"), item.accounts.sole.cash_balance
    assert_equal BigDecimal("100"), item.accounts.sole.balance
    assert_equal BigDecimal("2"), item.accounts.sole.holdings.sole.qty
    encrypted_cookie = ActiveRecord::Base.connection.select_value(
      "SELECT gsessionid FROM fineco_items WHERE id = #{ActiveRecord::Base.connection.quote(item.id)}"
    )
    refute_includes encrypted_cookie, "rotated-session-cookie"
  end

  test "capture returns the sanitized identity verification error before constructing a provider client" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    Provider::Fineco.stubs(:verified_identity_contract?).returns(false)
    Provider::Fineco.expects(:new).never
    item_count = FinecoItem.count
    account_count = FinecoAccount.count

    error = assert_raises(FinecoItem::PortfolioImportError) do
      with_fineco_access do
        @runtime.capture(
          identity: @runtime.identity,
          session: {
            gsessionid: "synthetic-session-cookie",
            account_index: "2",
            dossier_index: "4",
            captured_at: Time.current
          }
        )
      end
    end

    assert_equal "identity_verification_required", error.code
    assert_equal item_count, FinecoItem.count
    assert_equal account_count, FinecoAccount.count
    assert_not FinecoItem.exists?(family: @user.family, owner: @user)
  end

  test "capture rejects a different verified bank identity when request indexes are unchanged" do
    item = FinecoItem.create!(
      family: @user.family,
      owner: @user,
      gsessionid: "existing-session-cookie",
      account_index: "2",
      dossier_index: "4",
      captured_at: Time.current,
      bank_account_number: "SYNTHETIC-ACCOUNT-2",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier")
    )
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    result = RuntimeDouble::PortfolioResult.new(
      nil,
      "rotated-session-cookie",
      "DIFFERENT-ACCOUNT",
      Digest::SHA256.hexdigest("different-dossier")
    )
    client = mock("Fineco verification client")
    client.expects(:fetch_portfolio_summary).returns(result)
    Provider::Fineco.expects(:new).with(
      gsessionid: "new-session-cookie",
      account_index: "2",
      dossier_index: "4"
    ).returns(client)
    captured = nil
    with_fineco_access do
      captured = @runtime.capture(
        identity: @runtime.identity,
        session: {
          gsessionid: "new-session-cookie",
          account_index: "2",
          dossier_index: "4",
          captured_at: Time.current
        }
      )
    end

    assert_not captured
    assert_equal "existing-session-cookie", item.reload.gsessionid
    assert_equal "2", item.account_index
    assert_equal "4", item.dossier_index
    assert_equal "SYNTHETIC-ACCOUNT-2", item.bank_account_number
    assert_equal Digest::SHA256.hexdigest("synthetic-dossier"), item.dossier_identity
    assert_empty item.accounts
  end

  test "a pause invalidates a login flow that started before the pause" do
    item = build_fineco_item
    generation = item.connection_generation
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    item.disconnect!
    result = RuntimeDouble::PortfolioResult.new(
      nil,
      nil,
      "fineco-test-account",
      item.dossier_identity
    )
    client = mock("Fineco verification client")
    client.expects(:fetch_portfolio_summary).returns(result)
    Provider::Fineco.expects(:new).with(
      gsessionid: "new-session-cookie",
      account_index: "2",
      dossier_index: "4"
    ).returns(client)

    with_fineco_access do
      assert_not @runtime.capture(
        identity: @runtime.identity,
        session: {
          gsessionid: "new-session-cookie",
          account_index: "2",
          dossier_index: "4",
          captured_at: Time.current
        }
      )
    end

    assert item.reload.requires_update?
    assert_nil item.gsessionid
    assert_equal generation + 1, item.connection_generation
    assert_empty item.accounts
  end

  test "a new explicit reconnect after pausing can commit against the next generation" do
    item = build_fineco_item
    item.disconnect!
    generation = item.reload.connection_generation
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    result = RuntimeDouble::PortfolioResult.new(
      portfolio_payload,
      "rotated-session-cookie",
      "fineco-test-account",
      item.dossier_identity
    )
    client = mock("Fineco verification client")
    client.expects(:fetch_portfolio_summary).returns(result)
    Provider::Fineco.expects(:new).with(
      gsessionid: "new-session-cookie",
      account_index: "5",
      dossier_index: "7"
    ).returns(client)
    captured = nil

    with_fineco_access do
      captured = @runtime.capture(
        identity: @runtime.identity,
        session: {
          gsessionid: "new-session-cookie",
          account_index: "5",
          dossier_index: "7",
          captured_at: Time.current
        }
      )
    end

    assert captured
    assert item.reload.good?
    assert_equal "rotated-session-cookie", item.gsessionid
    assert_equal "5", item.account_index
    assert_equal "7", item.dossier_index
    assert_equal generation + 1, item.connection_generation
    assert_equal BigDecimal("0"), item.accounts.sole.cash_balance
    assert_equal BigDecimal("100"), item.accounts.sole.balance
  end

  test "an initial login flow cannot replace an item created after it started" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    item = build_fineco_item

    Provider::Fineco.expects(:new).never
    with_fineco_access do
      assert_not @runtime.capture(
        identity: @runtime.identity,
        session: {
          gsessionid: "stale-flow-cookie",
          account_index: "2",
          dossier_index: "4",
          captured_at: Time.current
        }
      )
    end

    assert_equal "synthetic-session-cookie", item.reload.gsessionid
  end

  test "an initial login flow cannot replace an item created during verification" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    result = RuntimeDouble::PortfolioResult.new(
      portfolio_payload,
      "rotated-session-cookie",
      "SYNTHETIC-ACCOUNT-2",
      Digest::SHA256.hexdigest("synthetic-dossier")
    )
    created_item = nil
    owner = @user
    client = Object.new
    client.define_singleton_method(:fetch_portfolio_summary) do
      created_item = FinecoItem.create!(
        family: owner.family,
        owner: owner,
        gsessionid: "synthetic-session-cookie",
        account_index: "2",
        dossier_index: "4",
        captured_at: Time.current,
        bank_account_number: "fineco-test-account",
        dossier_identity: Digest::SHA256.hexdigest("fineco-test-dossier"),
        status: "good"
      )
      result
    end
    Provider::Fineco.expects(:new).with(
      gsessionid: "captured-session-cookie",
      account_index: "2",
      dossier_index: "4"
    ).returns(client)

    with_fineco_access do
      assert_not @runtime.capture(
        identity: @runtime.identity,
        session: {
          gsessionid: "captured-session-cookie",
          account_index: "2",
          dossier_index: "4",
          captured_at: Time.current
        }
      )
    end

    assert_equal "synthetic-session-cookie", created_item.reload.gsessionid
    assert_equal 1, FinecoItem.where(family: @user.family, owner: @user).count
    assert_empty created_item.accounts
  end

  test "capture cancellation after verification writes no credential or account" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    result = RuntimeDouble::PortfolioResult.new(
      portfolio_payload,
      "rotated-session-cookie",
      "SYNTHETIC-ACCOUNT-2",
      Digest::SHA256.hexdigest("synthetic-dossier")
    )
    client = mock("Fineco verification client")
    client.expects(:fetch_portfolio_summary).returns(result)
    Provider::Fineco.expects(:new).returns(client)
    checks = 0
    cancelled = -> {
      checks += 1
      checks >= 5
    }
    account_count = @user.family.accounts.count

    assert_no_enqueued_jobs only: SyncJob do
      with_fineco_access do
        assert_not @runtime.capture(
          identity: @runtime.identity,
          session: {
            gsessionid: "captured-session-cookie",
            account_index: "2",
            dossier_index: "4",
            captured_at: Time.current
          },
          cancelled: cancelled
        )
      end
    end

    assert_equal 5, checks
    assert_not FinecoItem.exists?(family: @user.family, owner: @user)
    assert_empty FinecoAccount.joins(:fineco_item).where(fineco_items: { family_id: @user.family.id })
    assert_equal account_count, @user.family.accounts.count
  end

  test "capture rejects missing account indexes without creating an item" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end

    Provider::Fineco.expects(:new).never
    assert_no_difference "FinecoItem.count" do
      with_fineco_access do
        assert_not @runtime.capture(
          identity: @runtime.identity,
          session: {
            gsessionid: "captured-session-cookie",
            account_index: "",
            dossier_index: "4",
            captured_at: Time.current
          }
        )
      end
    end
  end

  test "capture rechecks the initiating identity and encryption before persistence" do
    with_fineco_access do
      post start_fineco_login_path, headers: json_headers
    end
    captured_session = {
      gsessionid: "captured-session-cookie",
      account_index: "2",
      dossier_index: "4",
      captured_at: Time.current
    }

    Provider::Fineco.expects(:new).never
    with_fineco_access do
      assert_not @runtime.capture(
        identity: @runtime.identity.merge("session_id" => "another-session"),
        session: captured_session
      )
    end

    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    with_fineco_access do
      assert_not @runtime.capture(identity: @runtime.identity, session: captured_session)
    end
    assert_not FinecoItem.exists?(family: @user.family, owner: @user)
  end

  private

    def with_fineco_access
      with_self_hosting do
        with_env_overrides(FINECO_BROWSER_ENABLED: "true") { yield }
      end
    end

    def json_headers
      { "Accept" => "application/json" }
    end

    def response_json
      JSON.parse(response.body)
    end

    def portfolio_payload
      position = {
        "instrId" => "US0000000002",
        "venueSystem" => "XETRA",
        "symbol" => "SYNTH",
        "description" => "Synthetic fund",
        "type" => "etf",
        "currencyCd" => "EUR",
        "qty" => "2",
        "avgPrice" => "45",
        "marketPrice" => "50",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "accrual" => "0.5",
        "ongoingAccrual" => "0.25"
      }
      summary = {
        "currencyCd" => "EUR",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "profitLossPerc" => "11.11",
        "accrual" => "0.5"
      }

      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => [ "EUR" ], "show" => [ "EUR" ] },
          "instrumentTypes" => { "total" => [ "etf" ], "show" => [ "etf" ] }
        },
        "positions" => { "show" => [ position ] },
        "summary" => { "show" => summary, "total" => summary }
      }
    end

    def build_fineco_item
      FinecoItem.create!(
        family: @user.family,
        owner: @user,
        gsessionid: "synthetic-session-cookie",
        account_index: "2",
        dossier_index: "4",
        captured_at: Time.current,
        bank_account_number: "fineco-test-account",
        dossier_identity: Digest::SHA256.hexdigest("fineco-test-dossier"),
        status: "good"
      )
    end
end
