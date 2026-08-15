class YaxiItemsController < ApplicationController
  layout "settings"

  before_action :ensure_admin
  before_action :ensure_configured
  before_action :set_yaxi_item, only: %i[connect complete refresh apply_refresh destroy]

  def new
    @yaxi_item = Current.family.yaxi_items.new(name: t("yaxi_items.connection_name"))
    render layout: "turbo_rails/frame" if turbo_frame_request?
  end

  def create
    item = Current.family.yaxi_items.create!(name: t("yaxi_items.connection_name"))
    redirect_to connect_yaxi_item_path(item), status: :see_other
  end

  def connect
    @ticket = issue_ticket("Accounts")
    @base_url = yaxi_provider.base_url
  end

  def complete
    connection_info = params.require(:connection_info).permit(:id, :displayName, :logoId).to_h

    ActiveRecord::Base.transaction do
      ticket, result = YaxiTicket.verify!(
        family: Current.family,
        user: Current.user,
        service: "Accounts",
        ticket_id: params.require(:ticket_id),
        token: params.require(:result_jwt),
        provider: yaxi_provider
      )
      @yaxi_item.complete_connection!(accounts_result: result.fetch("data"), connection_info: connection_info)
      ticket.consume!
    end

    render json: { redirect_url: refresh_yaxi_item_path(@yaxi_item) }
  rescue Provider::Yaxi::Error, ActiveRecord::RecordInvalid, KeyError => e
    capture_error(e, source: "YaxiItemsController#complete")
    render json: { error: t("yaxi_items.errors.invalid_result") }, status: :unprocessable_entity
  end

  def refresh
    redirect_to connect_yaxi_item_path(@yaxi_item), alert: t("yaxi_items.refresh.not_connected") and return unless @yaxi_item.good?

    @base_url = yaxi_provider.base_url
    preparation = yaxi_refresh.preparation
    @balances_ticket = preparation.fetch(:balances_ticket)
    @transaction_tickets = preparation.fetch(:transaction_tickets)
    @account_references = preparation.fetch(:account_references)
  end

  def apply_refresh
    transaction_results = Array(params[:transaction_results]).map do |entry|
      entry.permit(:account_id, :ticket_id, :result_jwt).to_h.symbolize_keys
    end
    yaxi_refresh.apply!(
      balances_ticket_id: params.require(:balances_ticket_id),
      balances_result_jwt: params.require(:balances_result_jwt),
      transaction_results: transaction_results
    )

    @yaxi_item.accounts.each { |account| account.sync_later(window_start_date: 90.days.ago.to_date) }
    render json: { redirect_url: accounts_path }
  rescue Provider::Yaxi::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
    capture_error(e, source: "YaxiItemsController#apply_refresh")
    render json: { error: t("yaxi_items.errors.invalid_result") }, status: :unprocessable_entity
  rescue => e
    capture_error(e, source: "YaxiItemsController#apply_refresh")
    Rails.error.report(e, handled: true)
    render json: { error: t("yaxi_items.errors.unexpected") }, status: :internal_server_error
  end

  def destroy
    @yaxi_item.destroy!
    redirect_to settings_providers_path, notice: t("yaxi_items.destroy.success")
  end

  private

    def set_yaxi_item
      @yaxi_item = Current.family.yaxi_items.find(params[:id])
    end

    def ensure_admin
      redirect_to root_path, alert: t("settings.providers.not_authorized") unless Current.user&.admin?
    end

    def ensure_configured
      return if Provider::YaxiAdapter.configured?

      redirect_to settings_providers_path, alert: t("yaxi_items.not_configured")
    end

    def yaxi_provider
      @yaxi_provider ||= Provider::YaxiAdapter.build_provider
    end

    def issue_ticket(service, data = nil)
      YaxiTicket.issue!(family: Current.family, user: Current.user, service: service, service_data: data)
    end

    def yaxi_refresh
      @yaxi_refresh ||= YaxiRefresh.new(item: @yaxi_item, user: Current.user, provider: yaxi_provider)
    end

    def capture_error(error, source:)
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: error.message,
        source: source,
        provider_key: "yaxi",
        family: Current.family,
        metadata: { yaxi_item_id: @yaxi_item&.id, error_class: error.class.name }
      )
    end
end
