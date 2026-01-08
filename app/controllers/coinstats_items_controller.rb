class CoinstatsItemsController < ApplicationController
  before_action :set_coinstats_item, only: [ :show, :edit, :update, :destroy, :sync ]

  def index
    @coinstats_items = Current.family.coinstats_items.ordered
  end

  def show
  end

  def new
    @coinstats_item = Current.family.coinstats_items.build
    @coinstats_items = Current.family.coinstats_items.where.not(api_key: nil)
    @blockchains = fetch_blockchain_options(@coinstats_items.first)
  end

  def create
    @coinstats_item = Current.family.coinstats_items.build(coinstats_item_params)
    @coinstats_item.name ||= t(".default_name")

    # Validate API key before saving
    unless validate_api_key(@coinstats_item.api_key)
      return render_error_response(@coinstats_item.errors.full_messages.join(", "))
    end

    if @coinstats_item.save
      render_success_response(".success")
    else
      render_error_response(@coinstats_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    # Validate API key if it's being changed
    unless validate_api_key(coinstats_item_params[:api_key])
      return render_error_response(@coinstats_item.errors.full_messages.join(", "))
    end

    if @coinstats_item.update(coinstats_item_params)
      render_success_response(".success")
    else
      render_error_response(@coinstats_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @coinstats_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    unless @coinstats_item.syncing?
      @coinstats_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def link_wallet
    coinstats_item_id = params[:coinstats_item_id].presence
    @address = params[:address]&.to_s&.strip.presence
    @blockchain = params[:blockchain]&.to_s&.strip.presence

    unless coinstats_item_id && @address && @blockchain
      return render_link_wallet_error(t(".missing_params"))
    end

    @coinstats_item = Current.family.coinstats_items.find(coinstats_item_id)

    result = CoinstatsItem::WalletLinker.new(@coinstats_item, address: @address, blockchain: @blockchain).link

    if result.success?
      redirect_to accounts_path, notice: t(".success", count: result.created_count), status: :see_other
    else
      error_msg = result.errors.join("; ").presence || t(".failed")
      render_link_wallet_error(error_msg)
    end
  rescue Provider::Coinstats::Error => e
    render_link_wallet_error(t(".error", message: e.message))
  rescue => e
    Rails.logger.error("CoinStats link wallet error: #{e.class} - #{e.message}")
    render_link_wallet_error(t(".error", message: e.message))
  end

  private

    def set_coinstats_item
      @coinstats_item = Current.family.coinstats_items.find(params[:id])
    end

    def coinstats_item_params
      params.require(:coinstats_item).permit(
        :name,
        :sync_start_date,
        :api_key
      )
    end

    def validate_api_key(api_key)
      return true if api_key.blank?

      response = Provider::Coinstats.new(api_key).get_blockchains
      if response.success?
        true
      else
        @coinstats_item.errors.add(:api_key, t("coinstats_items.create.errors.validation_failed", message: response.error&.message))
        false
      end
    rescue => e
      @coinstats_item.errors.add(:api_key, t("coinstats_items.create.errors.validation_failed", message: e.message))
      false
    end

    def render_error_response(error_message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "coinstats-providers-panel",
          partial: "settings/providers/coinstats_panel",
          locals: { error_message: error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: error_message, status: :unprocessable_entity
      end
    end

    def render_success_response(notice_key)
      if turbo_frame_request?
        flash.now[:notice] = t(notice_key, default: notice_key.to_s.humanize)
        @coinstats_items = Current.family.coinstats_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "coinstats-providers-panel",
            partial: "settings/providers/coinstats_panel",
            locals: { coinstats_items: @coinstats_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(notice_key), status: :see_other
      end
    end

    def render_link_wallet_error(error_message)
      @error_message = error_message
      @coinstats_items = Current.family.coinstats_items.where.not(api_key: nil)
      @blockchains = fetch_blockchain_options(@coinstats_items.first)
      render :new, status: :unprocessable_entity
    end

    def fetch_blockchain_options(coinstats_item)
      return [] unless coinstats_item&.api_key.present?

      Provider::Coinstats.new(coinstats_item.api_key).blockchain_options
    rescue Provider::Coinstats::Error => e
      Rails.logger.error("CoinStats blockchain fetch failed: item_id=#{coinstats_item.id} error=#{e.class} message=#{e.message}")
      flash.now[:alert] = t("coinstats_items.new.blockchain_fetch_error")
      []
    rescue StandardError => e
      Rails.logger.error("CoinStats blockchain fetch failed: item_id=#{coinstats_item.id} error=#{e.class} message=#{e.message}")
      flash.now[:alert] = t("coinstats_items.new.blockchain_fetch_error")
      []
    end
end
