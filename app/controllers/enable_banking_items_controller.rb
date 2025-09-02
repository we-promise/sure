class EnableBankingItemsController < ApplicationController
  before_action :set_enable_banking_item, only: %i[edit destroy sync]

  def index
    @enable_banking_items = Current.family.enable_banking_items.active.ordered
    @breadcrumbs = [ 
      [ "Home", root_path ], 
      [ "Bank Sync", settings_bank_sync_path ], 
      [ "Enable Banking", nil ] 
    ]
    render layout: "settings"
  end

  def new
    @enable_banking_item = Current.family.enable_banking_items.build
    available_aspsps = enable_banking_provider.get_available_aspsps
    @aspsps = available_aspsps.map do |aspsp|
      [aspsp["name"], aspsp["name"]]
    end
  rescue => error
    @enable_banking_item.errors.add(:base, t(".aspsp_error"))
  end

  def edit
  end

  def destroy
    @enable_banking_item.destroy_later
    redirect_to enable_banking_items_path, notice: t(".success")
  end

  def authorization
    aspsp_name = params[:aspsps_name]
    auth_url = enable_banking_provider.generate_authorization_url(aspsp_name)
    render json: { url: auth_url }
  rescue => error
    @enable_banking_item.errors.add(:base, t(".authorization_error"))
  end

  def auth_callback
    code = params[:code]
    if code.nil?
      Rails.logger.error("Failed to retrieve code from authentication callback parameters")
      redirect_to enable_banking_items_path, alert: t(".auth_failed")
    else
      session = enable_banking_provider.create_session(code)
      @enable_banking_item = Current.family.create_enable_banking_item!(
        session_id: session["session_id"],
        valid_until: session["access"]["valid_until"],
        item_name: session["aspsp"]["name"],
        logo_url: "https://enablebanking.com/brands/#{session['aspsp']['country']}/#{session['aspsp']['name']}",
        raw_payload: session.to_json
      )
      redirect_to enable_banking_items_path, notice: t(".success")
    end
  end

  def sync
    unless @enable_banking_item.syncing?
      @enable_banking_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  private
    def enable_banking_provider
      @enable_banking_provider ||= Provider::Registry.get_provider(:enable_banking)
    end
    
    def set_enable_banking_item
      @enable_banking_item = Current.family.enable_banking_items.find(params[:id])
    end

end
