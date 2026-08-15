class YaxiItemsController < ApplicationController
  layout "settings"

  before_action :ensure_admin
  before_action :ensure_configured
  before_action :set_yaxi_item, only: %i[connect complete refresh apply_refresh destroy]

  def new
    @yaxi_item = Current.family.yaxi_items.new(name: "YAXI Connection")
    render layout: "turbo_rails/frame" if turbo_frame_request?
  end

  def create
    item = Current.family.yaxi_items.create!(name: "YAXI Connection")
    redirect_to connect_yaxi_item_path(item), status: :see_other
  end

  def connect
    @ticket = issue_ticket("Accounts")
    @base_url = yaxi_provider.base_url
  end

  def complete
    ticket, result = verify_result!(service: "Accounts", ticket_id: params.require(:ticket_id), token: params.require(:result_jwt))
    connection_info = params.require(:connection_info).permit(:id, :displayName, :logoId).to_h

    ActiveRecord::Base.transaction do
      @yaxi_item.complete_connection!(accounts_result: result.fetch("data"), connection_info: connection_info)
      ticket.consume!
    end

    render json: { redirect_url: refresh_yaxi_item_path(@yaxi_item) }
  rescue Provider::Yaxi::Error, ActiveRecord::RecordInvalid, KeyError => e
    capture_error(e, source: "YaxiItemsController#complete")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def refresh
    redirect_to connect_yaxi_item_path(@yaxi_item), alert: t("yaxi_items.refresh.not_connected") and return unless @yaxi_item.good?

    @base_url = yaxi_provider.base_url
    @balances_ticket = issue_ticket("Balances")
    refreshable_accounts = @yaxi_item.yaxi_accounts.where.not(iban: [ nil, "" ])
    @transaction_tickets = refreshable_accounts.map do |account|
      from = [ account.account&.entries&.maximum(:date), 90.days.ago.to_date ].compact.max
      ticket = issue_ticket(
        "Transactions",
        {
          account: { iban: account.iban, currency: account.currency }.compact,
          range: { from: from.iso8601 }
        }
      )
      { account_id: account.id, ticket_id: ticket.id, token: ticket.token }
    end
    @account_references = refreshable_accounts.map { |account| { iban: account.iban, currency: account.currency }.compact }
  end

  def apply_refresh
    balances_ticket, balances_result = verify_result!(
      service: "Balances",
      ticket_id: params.require(:balances_ticket_id),
      token: params.require(:balances_result_jwt)
    )

    transaction_results = Array(params[:transaction_results]).map do |entry|
      permitted = entry.permit(:account_id, :ticket_id, :result_jwt)
      ticket, result = verify_result!(
        service: "Transactions",
        ticket_id: permitted.require(:ticket_id),
        token: permitted.require(:result_jwt)
      )
      account = @yaxi_item.yaxi_accounts.find(permitted.require(:account_id))
      ensure_transaction_ticket_matches!(ticket, account)
      [ account, ticket, result.fetch("data") ]
    end

    ActiveRecord::Base.transaction do
      apply_balances!(balances_result.fetch("data"))
      transaction_results.each do |account, ticket, transactions|
        account.import_transactions!(transactions)
        ticket.consume!
      end
      balances_ticket.consume!
      @yaxi_item.update!(last_refreshed_at: Time.current, status: :good)
    end

    @yaxi_item.accounts.each { |account| account.sync_later(window_start_date: 90.days.ago.to_date) }
    render json: { redirect_url: accounts_path }
  rescue Provider::Yaxi::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
    capture_error(e, source: "YaxiItemsController#apply_refresh")
    render json: { error: e.message }, status: :unprocessable_entity
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

    def verify_result!(service:, ticket_id:, token:)
      ticket = Current.family.yaxi_tickets.find_by!(id: ticket_id, user: Current.user, service: service)
      raise Provider::Yaxi::InvalidResultError, "YAXI ticket has already been used" if ticket.consumed_at.present?
      raise Provider::Yaxi::InvalidResultError, "YAXI ticket has expired" if ticket.expires_at <= Time.current

      [ ticket, yaxi_provider.verify_result(token, expected_ticket_id: ticket.id) ]
    end

    def apply_balances!(payload)
      groups = payload.is_a?(Array) ? payload : [ payload ]
      balance_groups = groups.flat_map do |group|
        group = group.with_indifferent_access
        group[:balances].present? ? Array(group[:balances]) : [ group ]
      end

      balance_groups.each do |entry|
        entry = entry.with_indifferent_access
        reference = entry.fetch("account")
        account = @yaxi_item.yaxi_accounts.find_by(iban: reference["iban"], currency: reference["currency"]) ||
                  @yaxi_item.yaxi_accounts.find_by(iban: reference["iban"])
        raise Provider::Yaxi::InvalidResultError, "YAXI balance does not match a connected account" unless account

        account.apply_balance_result!(entry.fetch("balances"))
      end
    end

    def ensure_transaction_ticket_matches!(ticket, account)
      expected = ticket.service_data.fetch("account").with_indifferent_access
      matches = expected[:iban] == account.iban && expected[:currency].to_s == account.currency.to_s
      raise Provider::Yaxi::InvalidResultError, "YAXI transaction ticket does not match the selected account" unless matches
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
