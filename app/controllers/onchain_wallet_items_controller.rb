# frozen_string_literal: true

# Self-custody wallet connections. Chain-agnostic throughout: a chain is a
# registry key that arrives as a parameter, gets validated against the registry,
# and is never branched on.
class OnchainWalletItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_onchain_wallet_item,
                only: %i[update destroy sync manage review_tokens update_tokens
                         disconnect_wallet disconnect_asset]
  before_action :set_wallet, only: %i[review_tokens update_tokens disconnect_wallet]

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

  # Turns the "no crypto prices configured" warning into one click. Without a
  # crypto-capable market data provider every on-chain holding is valued at zero,
  # which reads as a broken sync; making the user go and find the setting is how
  # that becomes a support ticket instead of a fix.
  def enable_crypto_prices
    unless self_hosted?
      return redirect_back_or_to settings_providers_path, alert: t(".not_self_hosted")
    end

    Onchain::SecurityResolver.enable_price_provider!

    redirect_back_or_to settings_providers_path, notice: t(".success")
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

    # Only now can the address be put in its canonical form: what counts as the
    # same address is a per-chain question, and the duplicate check has to run on
    # the canonical form or two spellings become two wallets.
    @address = Onchain::Chains.canonical_address(@chain, @address)

    return render_new_wallet(t(".errors.already_linked")) if Current.family.onchain_address_linked?(@chain, @address)

    snapshot = fetch_snapshot(@chain, @address)
    return render_new_wallet(@provider_error) if snapshot.nil?

    @assets_truncated = snapshot.assets_truncated?
    @review = OnchainWalletItem::TokenReview.new(snapshot: snapshot)
    render :token_review
  end

  # Step 3: track the assets that were ticked.
  def link_wallet
    @address = normalized_address
    @chain = requested_chain
    return render_new_wallet(t(".errors.unrecognized_address")) if @chain.blank? || @address.blank?

    @address = Onchain::Chains.canonical_address(@chain, @address)
    return render_new_wallet(t(".errors.already_linked")) if Current.family.onchain_address_linked?(@chain, @address)

    snapshot = fetch_snapshot(@chain, @address)
    return render_new_wallet(@provider_error) if snapshot.nil?

    # The connection is created only now. Reading the address needs none, so a
    # failed read must not leave an empty one behind — the same reason previewing
    # uses an unsaved one.
    result = OnchainWalletItem::WalletLinker
      .new(Current.family.onchain_wallet_item!, chain: @chain, address: @address)
      .link(snapshot: snapshot, selected_keys: params[:assets])

    unless result.success?
      @assets_truncated = snapshot.assets_truncated?
      @review = OnchainWalletItem::TokenReview.new(snapshot: snapshot)
      # Telling someone who ticked three assets to "pick at least one" sends them
      # back to tick the same three.
      flash.now[:alert] = if result.errors.any?
        t(".errors.none_tracked", assets: result.errors.to_sentence)
      else
        t(".errors.nothing_selected")
      end
      return render :token_review, status: :unprocessable_entity
    end

    flash[:alert] = t(".errors.some_failed", assets: result.errors.to_sentence) if result.errors.any?
    redirect_to accounts_path, notice: t(".success", count: result.created), status: :see_other
  end

  # Everything a linked wallet can have done to it, in one place.
  def manage
  end

  # The token screen again, with the address left alone. Without this the only
  # way to stop tracking one asset would be to change the address.
  def review_tokens
    snapshot = fetch_snapshot(@chain, @address)
    return redirect_to_manage(alert: @provider_error) if snapshot.nil?

    @assets_truncated = snapshot.assets_truncated?
    @review = review_for(snapshot)
  end

  def update_tokens
    snapshot = fetch_snapshot(@chain, @address)
    return redirect_to_manage(alert: @provider_error) if snapshot.nil?

    result = wallet_linker.revise(snapshot: snapshot, selected_keys: params[:assets])

    unless result.changed?
      @assets_truncated = snapshot.assets_truncated?
      @review = review_for(snapshot)
      flash.now[:alert] = if result.errors.any?
        t(".errors.none_tracked", assets: result.errors.to_sentence)
      else
        t(".errors.no_changes")
      end
      return render :review_tokens, status: :unprocessable_entity
    end

    flash[:alert] = t(".errors.some_failed", assets: result.errors.to_sentence) if result.errors.any?
    redirect_to_manage(notice: t(".success", created: result.created, removed: result.removed))
  end



  def disconnect_wallet
    removed = @onchain_wallet_item.disconnect_wallet!(chain: @chain, address: @address)

    redirect_to_manage(notice: t(".success", count: removed))
  end

  def disconnect_asset
    onchain_account = @onchain_wallet_item.onchain_wallet_accounts.find(params[:onchain_wallet_account_id])
    onchain_account.destroy!

    redirect_to_manage(notice: t(".success", symbol: onchain_account.symbol))
  end

  private
    def set_onchain_wallet_item
      @onchain_wallet_item = Current.family.onchain_wallet_items.find(params[:id])
    end

    # A wallet is a (chain, address) couple, and only one this connection already
    # tracks: every management action is scoped through the family's own item.
    def set_wallet
      @chain = requested_chain
      @address = normalized_address

      return if @chain.present? && @onchain_wallet_item.tracks_address?(@chain, @address)

      redirect_to_manage(alert: t("onchain_wallet_items.errors.wallet_not_found"))
    end

    def wallet_linker
      OnchainWalletItem::WalletLinker.new(@onchain_wallet_item, chain: @chain, address: @address)
    end

    def review_for(snapshot)
      OnchainWalletItem::TokenReview.new(
        snapshot: snapshot,
        tracked_accounts: @onchain_wallet_item.accounts_for_wallet(@chain, @address).to_a
      )
    end

    def redirect_to_manage(flash_message)
      redirect_to manage_onchain_wallet_item_path(@onchain_wallet_item), **flash_message, status: :see_other
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
