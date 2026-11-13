# Adds a Trade Republic connection. The login runs on a pending connection,
# and the TradeRepublicItem is created only once Trade Republic approves it.
class TradeRepublicPendingConnectionsController < ApplicationController
  include TradeRepublicLoginFlow

  before_action :require_admin!
  before_action :set_pending_connection, except: :create

  def create
    qr_login = params[:login_method] == "qr"
    @pending_connection = Current.family.trade_republic_pending_connections.build(pending_connection_params)
    @pending_connection.qr_login = qr_login
    @pending_connection.currency ||= Current.family.currency

    if !qr_login && @pending_connection.pin.blank?
      return render_new_connection_error(t("trade_republic_items.initiate_login.pin_required"))
    end
    return render_new_connection_error(@pending_connection.errors.full_messages.join(", ")) unless @pending_connection.valid?

    replaced_ids = Current.family.trade_republic_pending_connections.ids
    provider = @pending_connection.trade_republic_provider
    result = qr_login ? provider.initiate_qr_login : provider.initiate_login

    # One login at a time: a new attempt replaces one left unfinished. The
    # family lock keeps two attempts at once from both getting through. It
    # is a NO KEY UPDATE lock so a login being approved meanwhile can still
    # create its connection, whose family foreign key needs a KEY SHARE lock.
    # An attempt from another tab that was stored while Trade Republic
    # answered this one is newer, so it stays and this one is dropped.
    started = Current.family.with_lock("FOR NO KEY UPDATE") do
      next false unless Current.family.trade_republic_pending_connections.ids.sort == replaced_ids.sort

      Current.family.trade_republic_pending_connections.destroy_all
      @pending_connection.update!(pending_login_state: result.data.fetch("pending_login_b64"))
      true
    end
    unless started
      return redirect_to(settings_providers_path(anchor: "trade-republic"), status: :see_other) unless turbo_panel_request?

      return render turbo_stream: replace_panel_stream
    end
    qr_code_svg = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if qr_login && result.data["qr_code_payload"].present?

    return redirect_to(settings_providers_path(anchor: "trade-republic"), status: :see_other) unless turbo_panel_request?

    render turbo_stream: turbo_stream.replace(
      "trade-republic-providers-panel",
      partial: "settings/providers/trade_republic_panel",
      locals: { pending_connection: @pending_connection, qr_code_svg: qr_code_svg }
    )
  rescue Provider::TradeRepublicClient::Error => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "Trade Republic login initiation failed for a new connection: #{login_error_detail(e)}",
      source: "trade_republic",
      family: Current.family,
      provider_key: "trade_republic"
    )
    render_new_connection_error(e.message)
  end

  # Cancels the login; nothing was connected yet.
  def destroy
    @pending_connection.destroy!
    return redirect_to(settings_providers_path(anchor: "trade-republic"), status: :see_other) unless turbo_panel_request?

    render turbo_stream: replace_panel_stream
  end

  private

    def set_pending_connection
      @pending_connection = Current.family.trade_republic_pending_connections.find_by(id: params[:id])
      render_missing_pending_connection unless @pending_connection
    end

    # Cancelled, replaced or connected meanwhile, in another tab for example:
    # the request is outdated, so show the current state instead of a 404.
    def render_missing_pending_connection
      if request.format.json?
        render_superseded_qr_login
      elsif turbo_panel_request?
        render turbo_stream: replace_panel_stream
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), status: :see_other
      end
    end

    def pending_connection_params
      params.fetch(:trade_republic_pending_connection, {}).permit(:phone_number, :pin, :currency)
    end

    # The PIN login form opens again with the phone number kept.
    def render_new_connection_error(message)
      return redirect_to(settings_providers_path(anchor: "trade-republic"), alert: message, status: :see_other) unless turbo_panel_request?

      render turbo_stream: turbo_stream.replace(
        "trade-republic-providers-panel",
        partial: "settings/providers/trade_republic_panel",
        locals: { error_message: message, new_connection: @pending_connection }
      ), status: :unprocessable_entity
    end

    # TradeRepublicLoginFlow: the login belongs to a connection not created yet.
    def login_record
      @pending_connection
    end

    def start_qr_login!(pending_login_b64)
      @pending_connection.update!(pending_login_state: pending_login_b64)
    end

    # A cancelled login leaves nothing to keep. One that only lapsed keeps its
    # row, so the panel can say so until it is cancelled or a new login from
    # Add a connection replaces it.
    def end_login!(final:)
      return if @pending_connection.destroyed?

      final ? @pending_connection.destroy! : @pending_connection.update!(pending_login_state: nil)
    end

    def connect_login_record!(result)
      @pending_connection.connect!(
        session_blob: result.data.fetch("session_txt"),
        brokerage_account_id: account_id_from(result)
      )
    end

    def discard_duplicate_connection!
      end_login!(final: true)
    end

    def other_active_trade_republic_items
      Current.family.trade_republic_items.active
    end

    # The pending connection's row lives in the panel, which also shows the
    # add form again once the login has ended.
    def replace_login_record_stream
      replace_panel_stream
    end
end
