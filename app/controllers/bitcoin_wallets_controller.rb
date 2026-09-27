# frozen_string_literal: true

class BitcoinWalletsController < ApplicationController
  before_action :require_admin!
  before_action :require_preview_features!
  before_action :set_account
  before_action :set_wallet, except: %i[new create]

  def new
    @securities = bitcoin_securities
  end

  def create
    BitcoinWalletAccount.transaction do
      security = selected_security
      @wallet = BitcoinWalletAccount.new(account: @account, security: security,
        onchain_wallet_item: Current.family.onchain_wallet_item!)
      @wallet.save!
      @wallet.bitcoin_wallet_sources.create!(source_params)
    end
    BitcoinWalletSyncJob.perform_later(@wallet)
    redirect_to account_bitcoin_wallet_path(@account), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    @error_message = error.record.errors.full_messages.to_sentence
    @securities = bitcoin_securities
    render :new, status: :unprocessable_entity
  end

  def show
  end

  def connect
    @wallet.connect!
    redirect_to account_path(@account), notice: t("bitcoin_wallets.connected"), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_bitcoin_wallet_path(@account), alert: error.record.errors.full_messages.to_sentence, status: :see_other
  rescue ArgumentError
    redirect_to account_bitcoin_wallet_path(@account), alert: t("bitcoin_wallets.not_ready"), status: :see_other
  end

  def add_source
    @wallet.with_lock do
      @wallet.bitcoin_wallet_sources.create!(source_params)
      @wallet.sources_changed!
    end
    redirect_to account_bitcoin_wallet_path(@account), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    @error_message = error.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  end

  def remove_source
    @wallet.with_lock do
      @wallet.bitcoin_wallet_sources.find(params[:source_id]).destroy!
      if @wallet.bitcoin_wallet_sources.empty?
        @wallet.disconnect!
      else
        # Addresses are rediscovered from the retained source set; stale rows
        # must not keep a removed source's funds in the aggregate.
        @wallet.bitcoin_wallet_addresses.destroy_all
        @wallet.bitcoin_wallet_sources.each(&:reset_discovery!)
        @wallet.sources_changed!
      end
    end
    redirect_to account_path(@account), status: :see_other
  end

  def sync
    BitcoinWalletSyncJob.perform_later(@wallet)
    redirect_to account_bitcoin_wallet_path(@account), status: :see_other
  end

  def destroy
    @wallet.disconnect!
    redirect_to account_path(@account), notice: t("bitcoin_wallets.disconnected"), status: :see_other
  end

  private
    def set_account
      @account = Current.user.accessible_accounts.where(accountable_type: "Crypto").find(params[:account_id])
      head :forbidden unless @account.permission_for(Current.user).in?([ :owner, :full_control ])
    end

    def set_wallet
      @wallet = @account.bitcoin_wallet_account
      raise ActiveRecord::RecordNotFound unless @wallet && @wallet.onchain_wallet_item.family_id == Current.family.id
    end

    def source_params
      params.require(:source).permit(:kind, :receive_address, :extended_public_key, :gap_limit)
    end

    def bitcoin_securities
      ids = @account.holdings.distinct.pluck(:security_id) + @account.trades.distinct.pluck(:security_id)
      Security.where(id: ids.uniq).select { |security| security.ticker.to_s.upcase.match?(/\A(?:CRYPTO:)?(?:BTC|XBT)(?:-?USD)?\z/) }
    end

    def selected_security
      securities = bitcoin_securities
      if securities.empty?
        Onchain::SecurityResolver.resolve(symbol: "BTC", name: "Bitcoin")
      else
        securities.find { |security| security.id == params.dig(:source, :security_id) } || raise(ActiveRecord::RecordNotFound)
      end
    end
end
