# The Trade Republic login steps after a login has started: QR, push approval
# and authenticator code. They run for an existing connection logging in
# again (TradeRepublicItemsController) and for a new connection that is
# created only once the login succeeds (TradeRepublicPendingConnectionsController).
#
# The including controller provides:
# - login_record: the item or pending connection holding pending_login_state
# - start_qr_login!(pending_login_b64): stores a freshly started QR login
# - end_login!(final:): forgets the login; final for a cancel or duplicate,
#   not final when only the approval request lapsed
# - connect_login_record!(result): stores the approved session, returns the item
# - discard_duplicate_connection!: drops a login for an account already connected
# - other_active_trade_republic_items: connections a new login must not duplicate
# - replace_login_record_stream: re-renders the login's card
module TradeRepublicLoginFlow
  extend ActiveSupport::Concern

  # Step 2 of authentication: completes the started login. For push accounts
  # this is retried until Trade Republic reports CONFIRMED (status "pending");
  # authenticator accounts submit their code here. Success stores the session
  # and clears the pending login state.
  def complete_login
    provider = login_record.trade_republic_provider
    pending = login_record.pending_login_state
    unless provider && pending.present?
      redirect_to settings_providers_path(anchor: "trade-republic"), alert: login_t("no_pending_login"), status: :see_other
      return
    end

    result = provider.complete_login(
      pending_login_b64: pending,
      code: trade_republic_login_params[:code]
    )

    # Each outcome applies only while this code's login is still the current
    # one; a cancel or a newer login in another tab may have replaced it.
    if result.data["status"] == "pending"
      next_pending = result.data["pending_login_b64"].presence || pending
      return render_superseded_code_login unless store_pending_login_if_current!(pending, next_pending)

      if turbo_panel_request?
        render_login_panel(notice: login_t("approval_pending"))
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), notice: login_t("approval_pending")
      end
    elsif duplicate_connection?(result)
      return render_superseded_code_login unless end_login_if_current!(pending, final: true)

      discard_duplicate_connection!
      render_duplicate_login
    else
      begin
        return render_superseded_code_login unless connect_if_pending_login_current!(pending, result)
      rescue ActiveRecord::RecordNotUnique
        discard_duplicate_connection!
        return render_duplicate_login
      end
      if turbo_panel_request?
        render_login_panel(success: true)
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), notice: login_t("success")
      end
    end
  rescue Provider::TradeRepublicClient::InvalidChallenge => e
    redirect_to settings_providers_path(anchor: "trade-republic"), alert: e.message, status: :see_other
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired
    return render_superseded_code_login unless end_login_if_current!(pending, final: false)

    redirect_to settings_providers_path(anchor: "trade-republic"), alert: login_t("login_expired"), status: :see_other
  rescue Provider::TradeRepublicClient::Error => e
    redirect_to settings_providers_path(anchor: "trade-republic"), alert: e.message, status: :see_other
  end

  # Push approvals are asynchronous. The browser polls this endpoint while
  # the user approves the login in the Trade Republic app (maximum two minutes).
  def poll_login
    provider = login_record.trade_republic_provider
    pending = login_record.pending_login_state
    unless provider && pending.present?
      return render_login_panel(alert: login_t("no_pending_login"))
    end

    result = provider.complete_login(pending_login_b64: pending)
    if result.data["status"] == "pending"
      store_pending_login_if_current!(pending, result.data.fetch("pending_login_b64")) if result.data["pending_login_b64"].present?
      login_poll_response(:no_content) { render_login_panel }
    elsif duplicate_connection?(result)
      return render_superseded_push_login unless end_login_if_current!(pending, final: true)

      discard_duplicate_connection!
      render_login_panel(alert: t("trade_republic_items.duplicate_connection"), whole_panel: true)
    else
      begin
        return render_superseded_push_login unless connect_if_pending_login_current!(pending, result)
      rescue ActiveRecord::RecordNotUnique
        discard_duplicate_connection!
        return render_login_panel(alert: t("trade_republic_items.duplicate_connection"), whole_panel: true)
      end
      render_login_panel(success: true)
    end
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired
    return render_superseded_push_login unless end_login_if_current!(pending, final: false)

    render_login_panel(alert: login_t("login_expired"))
  rescue Provider::TradeRepublicClient::RateLimited => e
    capture_login_poll_error(e, login: "push", retryable: true)
    login_poll_response(:too_many_requests) { render_login_panel(alert: e.message) }
  rescue Provider::TradeRepublicClient::Timeout,
         Provider::TradeRepublicClient::TransientProviderError => e
    capture_login_poll_error(e, login: "push", retryable: true)
    login_poll_response(:service_unavailable) { render_login_panel(alert: e.message) }
  rescue Provider::TradeRepublicClient::Error => e
    capture_login_poll_error(e, login: "push", retryable: false)
    return render_superseded_push_login unless end_login_if_current!(pending, final: false)

    render_login_panel(alert: e.message)
  end

  def initiate_qr_login
    provider = login_record.trade_republic_provider
    raise Provider::TradeRepublicClient::ConfigurationError, login_t("not_configured") unless provider

    # A login started elsewhere while Trade Republic answered is newer; it
    # keeps its place and this tab shows it instead.
    previous = login_record.pending_login_state
    result = provider.initiate_qr_login
    started = with_current_pending_login(previous) { start_qr_login!(result.data.fetch("pending_login_b64")) }
    return render_superseded_qr_login unless started

    response_data = result.data.except("pending_login_b64")
    response_data["qr_code_svg"] = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if result.data["qr_code_payload"].present?
    render json: response_data, status: :accepted
  rescue Provider::TradeRepublicClient::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def poll_qr_login
    provider = login_record.trade_republic_provider
    pending = login_record.pending_login_state
    raise Provider::TradeRepublicClient::InvalidChallenge, login_t("no_pending_login") if provider.blank? || pending.blank?
    # A PIN login started in another tab replaced this QR login.
    return render_superseded_qr_login if pin_login_pending?

    result = provider.poll_qr_login(pending_login_b64: pending)
    if result.data["status"] == "pending"
      return render_superseded_qr_login unless store_pending_login_if_current!(pending, result.data.fetch("pending_login_b64"))

      response_data = result.data.except("pending_login_b64")
      response_data["qr_code_svg"] = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if result.data["qr_code_payload"].present?
      render json: response_data
    elsif duplicate_connection?(result)
      return render_superseded_qr_login unless end_login_if_current!(pending, final: true)

      discard_duplicate_connection!
      # The QR controller reloads the providers page for any non-pending
      # status, where this alert is shown.
      flash[:alert] = t("trade_republic_items.duplicate_connection")
      render json: { status: "duplicate_connection" }
    else
      begin
        return render_superseded_qr_login unless connect_if_pending_login_current!(pending, result)
      rescue ActiveRecord::RecordNotUnique
        discard_duplicate_connection!
        flash[:alert] = t("trade_republic_items.duplicate_connection")
        return render json: { status: "duplicate_connection" }
      end

      flash[:notice] = login_t("success")
      render json: result.data.except("session_txt")
    end
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired => e
    return render_superseded_qr_login unless end_login_if_current!(pending, final: false)

    render json: { error: e.message }, status: :unprocessable_entity
  rescue Provider::TradeRepublicClient::RateLimited => e
    render_qr_login_error(e, pending: pending, status: :too_many_requests, retryable: true)
  rescue Provider::TradeRepublicClient::Timeout,
         Provider::TradeRepublicClient::TransientProviderError => e
    render_qr_login_error(e, pending: pending, status: :service_unavailable, retryable: true)
  rescue Provider::TradeRepublicClient::Error => e
    render_qr_login_error(e, pending: pending)
  end

  # Only a QR login is this cancel's to end. A PIN login that replaced it (in
  # another tab, say) stays, and so does a working session whose QR login
  # never started; the card then shows the current state.
  def cancel_qr_login
    end_login!(final: true) if login_record.pending_login_state.present? && !pin_login_pending?
    respond_to do |format|
      format.turbo_stream { render turbo_stream: replace_login_record_stream }
      format.json { render json: { status: "cancelled" } }
    end
  end

  private

    # The actions are shared, so their messages live under trade_republic_items
    # whichever controller runs them.
    def login_t(key, **options)
      t("trade_republic_items.#{action_name}.#{key}", **options)
    end

    def trade_republic_login_params
      params.fetch(:trade_republic_login, {}).permit(:code)
    end

    def render_login_panel(alert: nil, notice: nil, success: false, whole_panel: false)
      if success
        # The login's card goes too: its push poller would otherwise keep
        # polling a login that has finished.
        return render turbo_stream: [
          replace_login_record_stream,
          turbo_stream.replace("drawer", view_context.turbo_frame_tag("drawer")),
          turbo_stream.replace(
            "modal",
            render_to_string(partial: "trade_republic_items/connection_success", formats: [ :html ])
          )
        ]
      end

      flash.now[:alert] = alert if alert
      flash.now[:notice] = notice if notice
      render turbo_stream: [
        whole_panel ? replace_panel_stream : replace_login_record_stream,
        *flash_notification_stream_items
      ]
    end

    def render_duplicate_login
      if turbo_panel_request?
        render_login_panel(alert: t("trade_republic_items.duplicate_connection"), whole_panel: true)
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), alert: t("trade_republic_items.duplicate_connection"), status: :see_other
      end
    end

    def replace_panel_stream
      turbo_stream.replace("trade-republic-providers-panel", partial: "settings/providers/trade_republic_panel")
    end

    # Connecting the same Trade Republic account through a second item would
    # import its accounts twice.
    def account_id_from(result)
      result.data.dig("account", "brokerage_account_id").presence
    end

    # trade_republic_accounts rows only exist once the importer's first sync
    # runs, so checking only those would let a second item finish login for
    # the same account in the gap before that job runs (or truly
    # concurrently). brokerage_account_id is written on the item itself the
    # moment login succeeds and is backed by a unique index, so this is an
    # early, user-facing check; the index (see discard_duplicate_connection!
    # callers) is what actually closes the race.
    def duplicate_connection?(result)
      account_id = account_id_from(result)
      return false if account_id.blank?

      other_active_trade_republic_items.exists?(brokerage_account_id: account_id) ||
        other_active_trade_republic_items
          .joins(:trade_republic_accounts)
          .where(trade_republic_accounts: { trade_republic_account_id: [ account_id, "cash:#{account_id}" ] })
          .exists?
    end

    def render_qr_login_error(error, pending: nil, status: :unprocessable_entity, retryable: false)
      capture_login_poll_error(error, login: "QR", retryable: retryable)

      # A newer login replaced this one meanwhile; its error is not news, and
      # offering Cancel for it would end the newer login.
      if pending.present?
        current =
          if error.respond_to?(:pending_login_b64) && error.pending_login_b64.present?
            store_pending_login_if_current!(pending, error.pending_login_b64)
          else
            with_current_pending_login(pending) { }
          end
        return render_superseded_qr_login unless current
      end

      render json: { error: error.message, retryable: retryable }, status: status
    end

    # The background poller lives on the card, so re-rendering the card for it
    # would reconnect it, restart its timeout and poll again without waiting.
    # The manual status button submits a Turbo form (no XHR header) and needs
    # the card back as feedback.
    def login_poll_response(poller_status)
      request.xhr? ? head(poller_status) : yield
    end

    # Malformed-response messages can quote the provider response body, so
    # only their class is logged.
    def login_error_detail(error)
      error.is_a?(Provider::TradeRepublicClient::MalformedResponse) ? error.class.name : "#{error.class} - #{error.message}"
    end

    def capture_login_poll_error(error, login:, retryable:)
      detail = login_error_detail(error)
      DebugLogEntry.capture(
        category: "sync",
        level: retryable ? "info" : "warn",
        message: "Trade Republic #{login} login poll failed for #{login_record.class.name} #{login_record.id} " \
                 "(#{retryable ? "retryable" : "fatal"}): #{detail}",
        source: "trade_republic",
        family: Current.family,
        provider_key: "trade_republic"
      )
    end

    # Cancellation or a newer login can replace the state while a poll is in
    # flight; only the poll that started from the current state may write.
    # A pending connection that was cancelled, replaced or connected meanwhile
    # is gone altogether, which makes the poll just as outdated.
    def with_current_pending_login(expected_pending)
      login_record.with_lock do
        current = login_record.pending_login_state == expected_pending
        yield if current
        current
      end
    rescue ActiveRecord::RecordNotFound
      false
    end

    def store_pending_login_if_current!(expected_pending, pending_login_b64)
      with_current_pending_login(expected_pending) { login_record.update!(pending_login_state: pending_login_b64) }
    end

    def end_login_if_current!(expected_pending, final:)
      with_current_pending_login(expected_pending) { end_login!(final: final) }
    end

    def connect_if_pending_login_current!(expected_pending, result)
      connected = with_current_pending_login(expected_pending) do
        @connected_item = connect_login_record!(result)
      end
      @connected_item.sync_later if connected && !@connected_item.syncing?
      connected
    end

    # A newer login owns the card now; leave its state and poller alone.
    def render_superseded_push_login
      login_poll_response(:no_content) { render_login_panel }
    end

    def pin_login_pending?
      login_record.login_stage.in?(%w[waiting_for_approval authenticator_code])
    end

    def render_superseded_code_login
      return render_login_panel if turbo_panel_request?

      redirect_to settings_providers_path(anchor: "trade-republic"), status: :see_other
    end

    def render_superseded_qr_login
      render json: { error: t("trade_republic_items.poll_qr_login.no_pending_login"), retryable: false }, status: :conflict
    end
end
