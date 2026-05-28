# frozen_string_literal: true

class OnchainWalletItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_onchain_wallet_item, only: %i[update destroy sync destroy_account]

  def create
    item = Current.family.onchain_wallet_items.build(onchain_wallet_item_params)
    item.name = item.name.presence || "On-chain Wallets"

    if item.save
      item.set_onchain_institution_defaults!
      render_success_response("On-chain Wallets connection saved.")
    else
      render_error_response(item.errors.full_messages.join(", "))
    end
  end

  def update
    attrs = onchain_wallet_item_params
    attrs.delete(:etherscan_api_key) if attrs[:etherscan_api_key].blank?

    if @onchain_wallet_item.update(attrs)
      render_success_response("On-chain Wallets connection updated.")
    else
      render_error_response(@onchain_wallet_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @onchain_wallet_item.destroy_later
    redirect_to settings_providers_path, notice: "Scheduled On-chain Wallets connection for deletion.", status: :see_other
  end

  def sync
    @onchain_wallet_item.sync_later unless @onchain_wallet_item.syncing?
    redirect_back_or_to settings_providers_path, notice: "On-chain Wallets sync started.", status: :see_other
  end

  def link_wallet
    chain = params[:chain].to_s
    address = params[:wallet_address].to_s.strip

    return render_error_response("Choose Bitcoin or Ethereum.") unless chain.in?(OnchainWalletAccount::CHAINS)
    return render_error_response("Wallet address is required.") if address.blank?

    item = Current.family.onchain_wallet_item!
    if chain == "ethereum" && !item.credentials_configured?
      return render_error_response("Add an Etherscan API key before linking an Ethereum wallet.")
    end

    validate_wallet_address!(item, chain, address)
    OnchainWalletItem::Importer.new(item).import_wallet!(chain: chain, address: address)
    item.process_accounts

    render_success_response("Wallet linked.")
  rescue Provider::MempoolSpace::Error, Provider::Etherscan::Error, ArgumentError => e
    render_error_response(e.message)
  rescue StandardError => e
    Rails.logger.error("On-chain wallet link failed: #{e.class} - #{e.message}")
    render_error_response("Could not link wallet. #{e.message}")
  end

  def destroy_account
    wallet_account = @onchain_wallet_item.onchain_wallet_accounts.find(params[:account_id])
    Account.transaction do
      link_ids = wallet_account.account_provider ? [ wallet_account.account_provider.id ] : []
      Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
      wallet_account.destroy!
    end

    redirect_to settings_providers_path, notice: "Wallet asset disconnected.", status: :see_other
  end

  private
    def set_onchain_wallet_item
      @onchain_wallet_item = Current.family.onchain_wallet_items.find(params[:id])
    end

    def onchain_wallet_item_params
      params.require(:onchain_wallet_item).permit(:name, :etherscan_api_key, :sync_start_date)
    end

    def validate_wallet_address!(item, chain, address)
      case chain
      when "bitcoin"
        raise Provider::MempoolSpace::InvalidAddressError, "Invalid Bitcoin address" unless item.mempool_space_provider.valid_address?(address)
      when "ethereum"
        raise Provider::Etherscan::InvalidAddressError, "Invalid Ethereum address" unless item.etherscan_provider&.valid_address?(address)
      end
    end

    def render_error_response(error_message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "onchain-wallet-providers-panel",
          partial: "settings/providers/onchain_wallet_panel",
          locals: { error_message: error_message, onchain_wallet_items: Current.family.onchain_wallet_items.active.ordered }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: error_message, status: :unprocessable_entity
      end
    end

    def render_success_response(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        render turbo_stream: [
          turbo_stream.replace(
            "onchain-wallet-providers-panel",
            partial: "settings/providers/onchain_wallet_panel",
            locals: { onchain_wallet_items: Current.family.onchain_wallet_items.active.ordered }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end
end
