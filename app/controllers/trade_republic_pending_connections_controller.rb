# Adds a Trade Republic connection. The login runs on a pending connection,
# and the TradeRepublicItem is created only once Trade Republic approves it.
class TradeRepublicPendingConnectionsController < ApplicationController
  include TradeRepublicLoginFlow

  before_action :require_admin!
  before_action :set_pending_connection, except: [ :new, :create ]

  # Adding another connection opens in the drawer, like other providers.
  def new
    @pending_connection = Current.family.trade_republic_pending_connections.build
  end

  def create
    qr_login = params[:login_method] == "qr"
    @pending_connection = Current.family.trade_republic_pending_connections.build(pending_connection_params)
    @pending_connection.qr_login = qr_login
    @pending_connection.currency ||= Current.family.currency

    if !qr_login && @pending_connection.pin.blank?
      return render_new_connection_error(t("trade_republic_items.initiate_login.pin_required"))
    end
    return render_new_connection_error(@pending_connection.errors.full_messages.join(", ")) unless @pending_connection.valid?

    provider = @pending_connection.trade_republic_provider
    result = qr_login ? provider.initiate_qr_login : provider.initiate_login

    # One login at a time: a new attempt replaces one left unfinished.
    Current.family.trade_republic_pending_connections.destroy_all
    @pending_connection.update!(pending_login_state: result.data.fetch("pending_login_b64"))
    qr_code_svg = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if qr_login && result.data["qr_code_payload"].present?

    return redirect_to(settings_providers_path(anchor: "trade-republic"), status: :see_other) unless turbo_panel_request?

    render turbo_stream: [
      turbo_stream.replace(
        "trade-republic-providers-panel",
        partial: "settings/providers/trade_republic_panel",
        locals: { pending_connection: @pending_connection, qr_code_svg: qr_code_svg }
      ),
      (close_drawer_stream if params[:in_drawer] == "1")
    ].compact
  rescue Provider::TradeRepublicClient::Error => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "Trade Republic login initiation failed for a new connection: #{e.message}",
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
      @pending_connection = Current.family.trade_republic_pending_connections.find(params[:id])
    end

    def pending_connection_params
      params.fetch(:trade_republic_pending_connection, {}).permit(:phone_number, :pin, :currency)
    end

    def close_drawer_stream
      turbo_stream.replace("drawer", view_context.turbo_frame_tag("drawer"))
    end

    # The first connection is added from the panel, later ones from the
    # drawer; the error shows in whichever form was used.
    def render_new_connection_error(message)
      return redirect_to(settings_providers_path(anchor: "trade-republic"), alert: message, status: :see_other) unless turbo_panel_request?

      render turbo_stream: [
        turbo_stream.replace(
          "trade-republic-providers-panel",
          partial: "settings/providers/trade_republic_panel",
          locals: { error_message: message, new_connection: @pending_connection }
        ),
        turbo_stream.replace(
          "trade-republic-new-connection",
          partial: "trade_republic_pending_connections/new_connection",
          locals: { pending_connection: @pending_connection, error_message: message }
        )
      ], status: :unprocessable_entity
    end

    # TradeRepublicLoginFlow: the login belongs to a connection not created yet.
    def login_record
      @pending_connection
    end

    def start_qr_login!(pending_login_b64)
      @pending_connection.update!(pending_login_state: pending_login_b64)
    end

    # A cancelled login leaves nothing to keep. One that only lapsed keeps its
    # row, so the QR login can start again from it.
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
