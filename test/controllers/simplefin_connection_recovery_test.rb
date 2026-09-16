require "test_helper"

# Command behavior and real commits live in ConnectionRecoveryTest. These
# rollback-fixture tests exercise routing, authorization and the web boundary.
class SimplefinConnectionRecoveryTest < ActionDispatch::IntegrationTest
  Command = SimplefinItem::ConnectionUpdate
  Fence = Provider::AccountData::LegacyWriterFence
  PRIVATE_INPUT = "private-setup-token-never-in-recovery".freeze

  setup do
    @actor = users(:family_admin)
    sign_in @actor
    @item = @actor.family.simplefin_items.create!(name: "Recovery connection",
      access_url: "https://private-user:private-password@example.com/access")
    @claim_id = SecureRandom.uuid
    Provider::Simplefin.any_instance.expects(:claim_access_url).never
  end

  test "recovery posts pass only the scoped item claim ID and current administrator" do
    recovery_actions.each do |action, method|
      Command.expects(method).with(@item, claim_id: @claim_id, actor: @actor).once

      post recovery_path(action), params: {
        claim_id: @claim_id, setup_token: PRIVATE_INPUT, access_url: PRIVATE_INPUT,
        family_id: families(:empty).id, old_simplefin_item_id: SecureRandom.uuid,
        simplefin_item: { setup_token: PRIVATE_INPUT }
      }

      assert_response :see_other
      assert_redirected_to edit_simplefin_item_path(@item)
      assert_equal I18n.t("simplefin_items.#{action}.success"), flash[:notice]
      refute_includes response.body, PRIVATE_INPUT
      refute_includes response.location, PRIVATE_INPUT
    end
  end

  test "signed out users cannot reach recovery commands" do
    @actor.sessions.destroy_all
    Command.expects(:retry_later).never
    Command.expects(:cancel).never

    recovery_actions.each_key do |action|
      post recovery_path(action), params: { claim_id: @claim_id }
      assert_redirected_to new_session_url
    end
  end

  test "family members cannot retry or cancel an administrator connection request" do
    @actor.sessions.destroy_all
    sign_in users(:family_member)
    Command.expects(:retry_later).never
    Command.expects(:cancel).never

    recovery_actions.each_key do |action|
      post recovery_path(action), params: { claim_id: @claim_id }
      assert_redirected_to accounts_path
      assert_equal I18n.t("shared.require_admin"), flash[:alert]
    end
  end

  test "foreign family items are rejected before the command boundary" do
    foreign = families(:empty).simplefin_items.create!(name: "Foreign recovery",
      access_url: "https://example.com/foreign-recovery")
    Command.expects(:retry_later).never
    Command.expects(:cancel).never

    recovery_actions.each_key do |action|
      post recovery_path(action, foreign), params: { claim_id: @claim_id }
      assert_response :not_found
    end
  end

  test "foreign and stale claim refusals return a localized message without claim or secret details" do
    recovery_actions.each do |action, method|
      error = action == :retry_connection ? ActiveRecord::RecordNotFound : Fence::OwnershipChanged
      Command.expects(method).with(@item, claim_id: @claim_id, actor: @actor).raises(error, PRIVATE_INPUT)
      DebugLogEntry.expects(:capture).never

      post recovery_path(action), params: { claim_id: @claim_id }

      assert_response :see_other
      assert_redirected_to edit_simplefin_item_path(@item)
      assert_equal I18n.t("simplefin_items.connection_recovery.errors.unavailable"), flash[:alert]
      refute_includes flash[:alert], @claim_id
      refute_includes response.body, PRIVATE_INPUT
    end
  end

  test "missing or structured claim parameters never reach the recovery command" do
    Command.expects(:retry_later).never
    Command.expects(:cancel).never

    recovery_actions.each_key do |action|
      [ {}, { claim_id: [ @claim_id ] }, { claim_id: { id: @claim_id } } ].each do |parameters|
        post recovery_path(action), params: parameters

        assert_response :see_other
        assert_redirected_to edit_simplefin_item_path(@item)
        assert_equal I18n.t("simplefin_items.connection_recovery.errors.unavailable"), flash[:alert]
      end
    end
  end

  test "busy work reports a retryable conflict without treating cancellation as successful" do
    recovery_actions.each do |action, method|
      error = action == :retry_connection ? ProviderCredentialClaim::Busy : Fence::Busy
      Command.expects(method).with(@item, claim_id: @claim_id, actor: @actor).raises(error, PRIVATE_INPUT)

      post recovery_path(action), params: { claim_id: @claim_id }

      assert_response :see_other
      assert_redirected_to edit_simplefin_item_path(@item)
      assert_equal I18n.t("simplefin_items.connection_recovery.errors.busy"), flash[:alert]
      assert_nil flash[:notice]
      refute_includes response.body, PRIVATE_INPUT
    end
  end

  test "unexpected recovery failures record only sanitized support metadata" do
    Command.expects(:retry_later).with(@item, claim_id: @claim_id, actor: @actor).raises(RuntimeError, PRIVATE_INPUT)
    DebugLogEntry.expects(:capture).with(
      category: "provider_sync_error", level: "error", message: "SimpleFIN connection recovery failed",
      source: "SimplefinItemsController", provider_key: "simplefin", family: @actor.family,
      metadata: { item_id: @item.id, action: "retry_connection", error_class: "RuntimeError" }
    ).once

    post recovery_path(:retry_connection), params: { claim_id: @claim_id, setup_token: PRIVATE_INPUT }

    assert_response :see_other
    assert_equal I18n.t("simplefin_items.connection_recovery.errors.unexpected"), flash[:alert]
    refute_includes response.body, PRIVATE_INPUT
  end

  test "edit renders separate ID-only recovery forms and passes the scoped pagination cursor" do
    cursor = SecureRandom.uuid
    older_cursor = SecureRandom.uuid
    request = safe_request
    page = Command::RecoveryPage.new(requests: [ request ], next_cursor: older_cursor)
    Command.expects(:recovery_requests).with(@item, actor: @actor, before: cursor).returns(page)

    get edit_simplefin_item_path(@item), params: { connection_requests_before: cursor }

    assert_response :success
    recovery_actions.each_key do |action|
      assert_select "form[action=?][method=post]", recovery_path(action), count: 1 do |forms|
        form = forms.sole
        assert_empty form.ancestors("form")
        names = form.css("input[name]").map { |input| input["name"] }.reject { |name| name == "authenticity_token" }
        assert_equal [ "claim_id" ], names
        assert_equal @claim_id, form.at_css("input[name=claim_id]")["value"]
      end
    end
    assert_select "a[href=?]", edit_simplefin_item_path(@item, connection_requests_before: older_cursor)
    assert_select "a[href=?]", edit_simplefin_item_path(@item)
    refute_includes response.body, @item.access_url
    refute_includes response.body, PRIVATE_INPUT
  end

  test "unavailable installed requests do not offer retry or cancellation" do
    request = safe_request(state: "installed", can_retry: false, can_cancel: false)
    Command.expects(:recovery_requests).with(@item, actor: @actor, before: nil)
      .returns(Command::RecoveryPage.new(requests: [ request ], next_cursor: nil))

    get edit_simplefin_item_path(@item)

    assert_response :success
    recovery_actions.each_key { |action| assert_select "form[action=?]", recovery_path(action), count: 0 }
    assert_includes response.body, I18n.t("simplefin_items.connection_recovery.descriptions.refresh_unavailable")
    refute_includes response.body, I18n.t("simplefin_items.connection_recovery.descriptions.installed")
  end

  test "invalid pagination renders a safe localized error without querying another target" do
    Command.expects(:recovery_requests).never

    get edit_simplefin_item_path(@item), params: { connection_requests_before: [ @claim_id ] }

    assert_response :success
    assert_includes response.body, I18n.t("simplefin_items.connection_recovery.errors.unavailable")
    recovery_actions.each_key { |action| assert_select "form[action=?]", recovery_path(action), count: 0 }
  end

  test "modal redirect renders the recovery notice inside the returned frame" do
    Command.expects(:cancel).with(@item, claim_id: @claim_id, actor: @actor)
    Command.expects(:recovery_requests).with(@item, actor: @actor, before: nil)
      .returns(Command::RecoveryPage.new(requests: [], next_cursor: nil))

    post recovery_path(:cancel_connection_update), params: { claim_id: @claim_id }, headers: { "Turbo-Frame" => "modal" }
    assert_response :see_other
    get response.location, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal" do
      assert_select "[role=status]", text: /#{Regexp.escape(I18n.t("simplefin_items.cancel_connection_update.success"))}/
    end
  end

  private

    def recovery_actions
      { retry_connection: :retry_later, cancel_connection_update: :cancel }
    end

    def recovery_path(action, item = @item)
      public_send("#{action}_simplefin_item_path", item)
    end

    def safe_request(state: "prepared", can_retry: true, can_cancel: true)
      Command::RecoveryRequest.new(id: @claim_id, created_at: Time.current, state: state,
        can_retry: can_retry, can_cancel: can_cancel)
    end
end
