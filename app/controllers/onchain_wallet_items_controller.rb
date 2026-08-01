# frozen_string_literal: true

class OnchainWalletItemsController < ApplicationController
  include StreamExtensions

  # Cap each Blockscout probe during EVM auto-detect so one unavailable chain
  # cannot stall wallet linking for the full HTTParty timeout.
  EVM_AUTO_DETECT_TIMEOUT = 3

  before_action :require_admin!
  before_action :set_onchain_wallet_item, only: %i[update destroy manage sync destroy_wallet destroy_account edit_wallet update_wallet]

  def new_wallet
    @onchain_wallet_item = Current.family.onchain_wallet_items.active.first
  end

  def create
    item = Current.family.onchain_wallet_items.build(onchain_wallet_item_params)
    item.name = item.name.presence || t("onchain_wallet_items.onchain_wallet_item.fallback_name")

    if item.save
      item.set_onchain_institution_defaults!
      render_success_response(t(".success"))
    else
      render_error_response(item.errors.full_messages.join(", "))
    end
  end

  def update
    attrs = onchain_wallet_item_params
    attrs.delete(:etherscan_api_key) if attrs[:etherscan_api_key].blank?

    if @onchain_wallet_item.update(attrs)
      render_success_response(t(".success"))
    else
      render_error_response(@onchain_wallet_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @onchain_wallet_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def manage
  end

  def sync
    @onchain_wallet_item.sync_later unless @onchain_wallet_item.syncing?
    redirect_back_or_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def link_wallet
    chain = params[:chain].to_s
    address = params[:wallet_address].to_s.strip

    return render_error_response(t(".address_required")) if address.blank?

    # "auto" (or blank) → detect the chain from the address format; for EVM
    # addresses, pick the first supported chain the address is active on.
    if chain.blank? || chain == "auto"
      chain = resolve_auto_chain(address)
      return render_error_response(t(".chain_undetected")) if chain.blank?
    end

    return render_error_response(t(".unsupported_chain")) unless chain.in?(OnchainWalletAccount::CHAINS)

    # EVM chains are read keyless via Blockscout, so no API key gate is needed.
    item = Current.family.onchain_wallet_items.active.first
    item ||= Current.family.onchain_wallet_item!

    validate_wallet_address!(item, chain, address)
    importer = OnchainWalletItem::Importer.new(item)

    evm = OnchainWalletAccount.evm_chain?(chain)

    if evm && !evm_token_review_confirmed?
      preview = importer.preview_evm_wallet(chain, address)
      token_candidates = preview[:token_holdings].select { |holding| holding[:quantity].positive? }
      return render_token_review_response(chain, preview, address) if token_candidates.any?
    end

    if evm
      importer.import_evm_wallet!(
        chain: chain,
        address: address,
        selected_token_contracts: params[:selected_token_contracts]
      )
    else
      importer.import_wallet!(chain: chain, address: address)
    end
    item.process_accounts
    item.schedule_account_syncs

    render_success_response(t(".success"))
  rescue Provider::MempoolSpace::Error, Provider::Etherscan::Error, Provider::Blockscout::Error, Provider::SolanaRpc::Error, Provider::BittensorRpc::Error, ArgumentError => e
    render_error_response(e.message)
  rescue StandardError => e
    Rails.logger.error("On-chain wallet link failed: #{e.class} - #{e.message}")
    render_error_response(t(".link_failed", message: e.message))
  end

  def edit_wallet
    @chain = params[:chain].to_s.downcase
    @old_address = normalized_wallet_address(@chain, params[:wallet_address])
    @wallet_accounts = @onchain_wallet_item.onchain_wallet_accounts.where(chain: @chain, wallet_address: @old_address).order(:asset_kind, :symbol)

    if @wallet_accounts.empty?
      redirect_back_or_to(accounts_path, alert: t(".not_found"), status: :see_other)
    end
  end

  def update_wallet
    chain = params[:chain].to_s.downcase
    old_address = normalized_wallet_address(chain, params[:old_wallet_address])
    new_address = params[:wallet_address].to_s.strip
    new_address = new_address.downcase if OnchainWalletAccount.evm_chain?(chain)

    return render_edit_error(chain, old_address, new_address, t(".address_required")) if new_address.blank?
    return render_edit_error(chain, old_address, new_address, t(".same_address")) if new_address == old_address

    existing_for_old = @onchain_wallet_item.onchain_wallet_accounts.where(chain: chain, wallet_address: old_address)
    return render_edit_error(chain, old_address, new_address, t(".not_found")) if existing_for_old.none?

    if @onchain_wallet_item.onchain_wallet_accounts.where(chain: chain, wallet_address: new_address).exists?
      return render_edit_error(chain, old_address, new_address, t(".already_linked"))
    end

    validate_wallet_address!(@onchain_wallet_item, chain, new_address)

    importer = OnchainWalletItem::Importer.new(@onchain_wallet_item)

    evm = OnchainWalletAccount.evm_chain?(chain)

    if evm && !evm_token_review_confirmed?
      preview = importer.preview_evm_wallet(chain, new_address)
      existing_contracts = existing_for_old.where(asset_kind: "erc20").pluck(:token_contract).map { |contract| contract.to_s.downcase }
      new_token_candidates = preview[:token_holdings].select { |holding| holding[:quantity].positive? && !existing_contracts.include?(holding[:contract]) }
      existing_token_accounts = existing_for_old.where(asset_kind: "erc20").to_a

      return render turbo_stream: turbo_stream.replace(
        "modal",
        partial: "onchain_wallet_items/wallet_edit_token_review",
        locals: {
          onchain_wallet_item: @onchain_wallet_item,
          chain: chain,
          old_address: old_address,
          new_address: new_address,
          preview: preview,
          existing_token_accounts: existing_token_accounts,
          new_token_candidates: new_token_candidates
        }
      )
    end

    selected_existing = Array(params[:selected_existing_token_contracts]).map { |contract| contract.to_s.downcase }
    selected_new = Array(params[:selected_token_contracts]).map { |contract| contract.to_s.downcase }

    # For EVM address changes: drop existing ERC20 rows the user unchecked, and
    # also drop selected ones the new address does not actually hold. Otherwise
    # update_all would move stale quantity/balance/payload onto the new wallet
    # and import_evm_wallet would never overwrite them (no transfers → no upsert).
    selected_existing_to_keep = selected_existing
    if evm
      preview = importer.preview_evm_wallet(chain, new_address)
      present_contracts = preview[:token_holdings].map { |holding| holding[:contract].to_s.downcase }.to_set
      selected_existing_to_keep = selected_existing.select { |contract| present_contracts.include?(contract) }
    end

    OnchainWalletAccount.transaction do
      if evm
        to_remove = existing_for_old.where(asset_kind: "erc20").reject { |wallet_account|
          selected_existing_to_keep.include?(wallet_account.token_contract.to_s.downcase)
        }
        remove_wallet_accounts!(to_remove) if to_remove.any?
      end

      @onchain_wallet_item.onchain_wallet_accounts
        .where(chain: chain, wallet_address: old_address)
        .update_all(wallet_address: new_address)
    end

    if evm
      importer.import_evm_wallet!(
        chain: chain,
        address: new_address,
        selected_token_contracts: (selected_existing_to_keep + selected_new).uniq
      )
    else
      importer.import_wallet!(chain: chain, address: new_address)
    end
    @onchain_wallet_item.process_accounts
    @onchain_wallet_item.schedule_account_syncs

    render_success_response(t(".success"))
  rescue Provider::MempoolSpace::Error, Provider::Etherscan::Error, Provider::Blockscout::Error, Provider::SolanaRpc::Error, Provider::BittensorRpc::Error, ArgumentError => e
    render_edit_error(chain, old_address, new_address, e.message)
  rescue StandardError => e
    Rails.logger.error("On-chain wallet update failed: #{e.class} - #{e.message}")
    render_edit_error(chain, old_address, new_address, t(".update_failed", message: e.message))
  end

  def destroy_account
    wallet_account = @onchain_wallet_item.onchain_wallet_accounts.find(params[:account_id])
    remove_wallet_accounts!([ wallet_account ])

    redirect_back_or_to accounts_path, notice: t(".success"), status: :see_other
  end

  def destroy_wallet
    wallet_accounts = @onchain_wallet_item.onchain_wallet_accounts.where(
      chain: params[:chain].to_s.downcase,
      wallet_address: normalized_wallet_address(params[:chain], params[:wallet_address])
    )
    return redirect_back_or_to(accounts_path, alert: t(".not_found"), status: :see_other) if wallet_accounts.empty?

    remove_wallet_accounts!(wallet_accounts)

    redirect_back_or_to accounts_path, notice: t(".success"), status: :see_other
  end

  private
    def remove_wallet_accounts!(wallet_accounts)
      accounts = wallet_accounts.is_a?(ActiveRecord::Relation) ? wallet_accounts.to_a : Array(wallet_accounts)

      Account.transaction do
        link_ids = accounts.filter_map { |wallet_account| wallet_account.account_provider&.id }
        Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
        accounts.each(&:destroy!)
      end
    end

    def set_onchain_wallet_item
      @onchain_wallet_item = Current.family.onchain_wallet_items.find(params[:id])
    end

    def onchain_wallet_item_params
      params.require(:onchain_wallet_item).permit(:name, :ethereum_data_provider, :etherscan_api_key, :sync_start_date)
    end

    def resolve_auto_chain(address)
      case OnchainWalletAccount.detect_chain_type(address)
      when :bitcoin then "bitcoin"
      when :bittensor then "bittensor"
      when :solana  then "solana"
      when :evm
        OnchainWalletAccount::EVM_CHAINS.find { |chain| evm_chain_has_activity?(chain, address) } || "ethereum"
      end
    end

    # Runs each chain's activity check independently. Timeouts and transport
    # errors count as "no activity" so detection continues in CHAINS order.
    def evm_chain_has_activity?(chain, address)
      Timeout.timeout(EVM_AUTO_DETECT_TIMEOUT) do
        Provider::Blockscout.new(chain: chain).has_activity?(address)
      end
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError,
           Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT
      false
    end

    def validate_wallet_address!(item, chain, address)
      if chain == "bitcoin"
        raise Provider::MempoolSpace::InvalidAddressError, t("onchain_wallet_items.errors.invalid_bitcoin_address") unless item.mempool_space_provider.valid_address?(address)
      elsif OnchainWalletAccount.evm_chain?(chain)
        provider = item.evm_provider(chain)
        error_class =
          if provider.is_a?(Provider::Etherscan)
            Provider::Etherscan::InvalidAddressError
          else
            Provider::Blockscout::InvalidAddressError
          end
        raise error_class, t("onchain_wallet_items.errors.invalid_evm_address") unless provider.valid_address?(address)
      elsif chain == "solana"
        raise Provider::SolanaRpc::InvalidAddressError, t("onchain_wallet_items.errors.invalid_solana_address") unless item.solana_provider.valid_address?(address)
      elsif chain == "bittensor"
        raise Provider::BittensorRpc::InvalidAddressError, t("onchain_wallet_items.errors.invalid_bittensor_address") unless item.bittensor_provider.valid_address?(address)
      end
    end

    def render_edit_error(chain, old_address, new_address, error_message)
      wallet_accounts = @onchain_wallet_item.onchain_wallet_accounts.where(chain: chain, wallet_address: old_address).order(:asset_kind, :symbol)
      render turbo_stream: turbo_stream.replace(
        "modal",
        partial: "onchain_wallet_items/wallet_edit_modal",
        locals: {
          onchain_wallet_item: @onchain_wallet_item,
          chain: chain,
          old_address: old_address,
          new_address: new_address,
          wallet_accounts: wallet_accounts,
          error_message: error_message
        }
      ), status: :unprocessable_entity
    end

    def render_error_response(error_message)
      if account_modal_request?
        @onchain_wallet_item = Current.family.onchain_wallet_items.active.first
        return render turbo_stream: turbo_stream.replace(
          "modal",
          partial: "onchain_wallet_items/wallet_modal",
          locals: {
            error_message: error_message,
            selected_chain: params[:chain].to_s,
            wallet_address: params[:wallet_address].to_s
          }
        ), status: :unprocessable_entity
      end

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
      if account_modal_request?
        return stream_redirect_to(accounts_path, notice: message)
      end

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

    def account_modal_request?
      params[:source] == "account_modal" || request.headers["Turbo-Frame"] == "modal"
    end

    def evm_token_review_confirmed?
      params[:reviewed_tokens] == "1"
    end

    def render_token_review_response(chain, preview, address)
      render turbo_stream: turbo_stream.replace(
        "modal",
        partial: "onchain_wallet_items/wallet_token_review",
        locals: {
          chain: chain,
          wallet_address: address,
          preview: preview,
          token_candidates: preview[:token_holdings].select { |holding| holding[:quantity].positive? }
        }
      )
    end

    def normalized_wallet_address(chain, address)
      return address.to_s.strip.downcase if OnchainWalletAccount.evm_chain?(chain)

      address.to_s.strip
    end
end
