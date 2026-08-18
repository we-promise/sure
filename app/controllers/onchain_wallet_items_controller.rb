# frozen_string_literal: true

# Self-custody wallet connections. Chain-agnostic throughout: a chain is a
# registry key that arrives as a parameter, gets validated against the registry,
# and is never branched on.
class OnchainWalletItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_onchain_wallet_item, only: %i[update destroy sync]

  def update
    if @onchain_wallet_item.update(onchain_wallet_item_params)
      render_panel_success(t(".success"))
    else
      render_panel_error(@onchain_wallet_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @onchain_wallet_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @onchain_wallet_item.sync_later unless @onchain_wallet_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  # Step 1: paste an address.
  def new_wallet
    @address = nil
  end

  # Step 2: work out the chain if it wasn't given, then show what is there.
  def preview_wallet
    @address = normalized_address
    return render_new_wallet(t(".errors.address_required")) if @address.blank?

    @chain = requested_chain
    if @chain.blank?
      detection = OnchainWalletItem::ChainDetector.new(preview_item, @address).detect
      return render_new_wallet(t(".errors.unrecognized_address")) if detection.unrecognized?

      if detection.ambiguous?
        @detection = detection
        return render :choose_chain
      end

      @chain = detection.chain
    end

    return render_new_wallet(t(".errors.already_linked")) if Current.family.onchain_address_linked?(@chain, @address)

    snapshot = fetch_snapshot(@chain, @address)
    return render_new_wallet(@provider_error) if snapshot.nil?

    @review = OnchainWalletItem::TokenReview.new(snapshot: snapshot)
    render :token_review
  end

  # Step 3: track the assets that were ticked.
  def link_wallet
    @address = normalized_address
    @chain = requested_chain
    return render_new_wallet(t(".errors.unrecognized_address")) if @chain.blank? || @address.blank?
    return render_new_wallet(t(".errors.already_linked")) if Current.family.onchain_address_linked?(@chain, @address)

    item = Current.family.onchain_wallet_item!
    snapshot = fetch_snapshot(@chain, @address)
    return render_new_wallet(@provider_error) if snapshot.nil?

    result = OnchainWalletItem::WalletLinker
      .new(item, chain: @chain, address: @address)
      .link(snapshot: snapshot, selected_keys: params[:assets])

    unless result.success?
      @review = OnchainWalletItem::TokenReview.new(snapshot: snapshot)
      flash.now[:alert] = t(".errors.nothing_selected")
      return render :token_review, status: :unprocessable_entity
    end

    redirect_to accounts_path, notice: t(".success", count: result.created), status: :see_other
  end

  private
    def set_onchain_wallet_item
      @onchain_wallet_item = Current.family.onchain_wallet_items.find(params[:id])
    end

    def onchain_wallet_item_params
      permitted = params.require(:onchain_wallet_item).permit(:sync_start_date, :etherscan_api_key)
      # Blank means "leave the stored key alone", not "clear it".
      permitted.delete(:etherscan_api_key) if permitted[:etherscan_api_key].blank?
      permitted
    end

    # Reading an address needs no saved connection, so previewing one never
    # leaves an empty item behind for an abandoned flow.
    def preview_item
      @preview_item ||= Current.family.onchain_wallet_item ||
        Current.family.onchain_wallet_items.new(name: I18n.t("onchain.institution_name"))
    end

    def normalized_address
      params[:address].to_s.strip
    end

    # Only a chain the registry knows can get through.
    def requested_chain
      chain = params[:chain].to_s.strip
      Onchain::Chains.exists?(chain) ? chain : nil
    end

    # Expected data-source failures become a localized message. Anything else is
    # a bug: the user gets a generic message and the details go to the debug log,
    # never into the response.
    def fetch_snapshot(chain, address)
      OnchainWalletItem::Importer.new(preview_item).fetch_snapshot(chain: chain, address: address)
    rescue Onchain::Chains::RateLimitedError
      @provider_error = t("onchain_wallet_items.errors.rate_limited")
      nil
    rescue Onchain::Chains::UnreachableError
      @provider_error = t("onchain_wallet_items.errors.chain_unreachable")
      nil
    rescue Onchain::Chains::Error
      @provider_error = t("onchain_wallet_items.errors.unrecognized_address")
      nil
    rescue StandardError => e
      capture_unexpected(e, chain: chain)
      @provider_error = t("onchain_wallet_items.errors.unexpected")
      nil
    end

    def capture_unexpected(error, chain:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Unexpected on-chain wallet failure: #{error.class}",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: Current.family,
        metadata: { chain: chain, error: error.message }
      )
    end

    def render_new_wallet(error_message, status: :unprocessable_entity)
      @error_message = error_message
      render :new_wallet, status: status
    end

    def render_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        @onchain_wallet_items = Current.family.onchain_wallet_items.active.ordered
        render turbo_stream: [
          turbo_stream.update(
            "onchain_wallet-providers-panel",
            partial: "settings/providers/onchain_wallet_panel",
            locals: { onchain_wallet_items: @onchain_wallet_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end

    def render_panel_error(message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.update(
          "onchain_wallet-providers-panel",
          partial: "settings/providers/onchain_wallet_panel",
          locals: { error_message: message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: message, status: :see_other
      end
    end
end
