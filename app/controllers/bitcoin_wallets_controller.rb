# frozen_string_literal: true

class BitcoinWalletsController < ApplicationController
  SOURCE_FIELDS = %i[extended_public_key gap_limit receive_address].freeze

  before_action :require_admin!
  before_action :require_preview_features!
  before_action :set_account
  before_action :set_wallet, except: %i[new create]

  # Render source setup and the account's existing BTC security choices.
  def new
    return redirect_to account_bitcoin_wallet_path(@account) if @account.bitcoin_wallet_account

    @securities = bitcoin_securities
    @form_values = {}
  end

  # Create draft tracking and its prerequisites atomically, then queue discovery
  # without changing the account's existing balances or holdings.
  def create
    BitcoinWalletAccount.transaction do
      security = selected_security
      @wallet = BitcoinWalletAccount.new(account: @account, security: security,
        onchain_wallet_item: Current.family.onchain_wallet_item!)
      @wallet.save!
      @wallet.bitcoin_wallet_sources.create!(source_params)
    end
    @wallet.sync_later
    redirect_to account_bitcoin_wallet_path(@account), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    keep_failed_source(error)
    @securities = bitcoin_securities
    render :new, status: :unprocessable_entity
  end

  # Render the discovery result, source controls and latest complete quantity;
  # the view never displays the stored extended public key.
  def show
    prepare_show
  end

  # Reconcile a ready preview into the existing account, reporting setup errors
  # without allowing an incomplete wallet snapshot to be linked.
  def connect
    @wallet.connect!
    redirect_to account_path(@account), notice: t("bitcoin_wallets.connected"), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_path(@account), alert: error.record.errors.full_messages.to_sentence, status: :see_other
  rescue ArgumentError
    redirect_to account_path(@account), alert: t("bitcoin_wallets.not_ready"), status: :see_other
  end

  # Add a validated source under the wallet lock and queue quantity reconciliation
  # for any existing connection after the new source set has been read.
  def add_source
    @wallet.with_lock do
      @wallet.bitcoin_wallet_sources.create!(source_params)
      @wallet.sources_changed!
    end
    redirect_to account_bitcoin_wallet_path(@account), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    keep_failed_source(error)
    prepare_show
    render :show, status: :unprocessable_entity
  end

  # Remove one source and rediscover retained ownership, or disconnect when the
  # last source is removed. Previously imported account history is retained.
  def remove_source
    notice = t("bitcoin_wallets.source_removed")
    @wallet.with_lock do
      @wallet.bitcoin_wallet_sources.find(params[:source_id]).destroy!
      if @wallet.bitcoin_wallet_sources.empty?
        @wallet.disconnect!
        notice = t("bitcoin_wallets.disconnected")
      else
        # Addresses are rediscovered from the retained source set; stale rows
        # must not keep a removed source's funds in the aggregate.
        @wallet.bitcoin_wallet_addresses.destroy_all
        @wallet.sources_changed!
      end
    end
    redirect_to account_path(@account), notice: notice, status: :see_other
  end

  # Request a background wallet refresh through the same authorized account route.
  def sync
    @wallet.sync_later
    redirect_to account_bitcoin_wallet_path(@account), status: :see_other
  end

  # Stop wallet tracking while leaving the Crypto account available manually.
  def destroy
    notice = t(@wallet.account_provider ? "bitcoin_wallets.disconnected" : "bitcoin_wallets.setup_cancelled")
    @wallet.disconnect!
    redirect_to account_path(@account), notice: notice, status: :see_other
  end

  private
    # Bound address rendering and prepare quantities, progress and safe error copy.
    def prepare_show
      @address_count = @wallet.bitcoin_wallet_addresses.count
      @addresses = @wallet.bitcoin_wallet_addresses.order(:branch, :address_index, :address).limit(100)
      @sources = @wallet.bitcoin_wallet_sources.order(:created_at)
      @previous_quantity = @account.current_holdings.find_by(security: @wallet.security)&.qty || 0
      @pending_quantity = @wallet.pending_quantity
      price = BitcoinWalletAccount::Processor.new(@wallet).price_on(Date.current) if @wallet.last_synced_at
      @value = Money.new(@wallet.quantity * price, @account.currency) if price
      @quantity_difference = @wallet.quantity - @previous_quantity.to_d
      @replaced_balance = @account.balance_money if @wallet.account_provider.nil? && @account.balance.nonzero? && @account.typed_balance_only?
      @discovery_checked = @sources.sum { |source| source.discovery.values_at("0", "1").compact.sum { |branch| branch.fetch("index", 0).to_i } }
      @hd_wallet = @sources.any? { |source| source.kind == "bip84" }
      @form_values ||= {}
      @wallet_error_key = case @wallet.last_error
      when "BitcoinWalletAccount::Discovery::AddressMismatch" then "address_mismatch"
      when "BitcoinWalletAccount::Discovery::Conflict" then "address_conflict"
      when "MissingPrice" then "missing_price"
      when "BitcoinWalletAccount::Snapshot::ChangedTip", "BitcoinWalletAccount::Snapshot::IncompleteMempool",
           /\AProvider::MempoolSpace::/ then "temporary_failure"
      else "failed"
      end
    end

    # Restrict management to an accessible Crypto account on which the current
    # user has owner or full-control permission, in addition to the admin gate.
    def set_account
      @account = Current.user.accessible_accounts.where(accountable_type: "Crypto").find(params[:account_id])
      head :forbidden unless @account.permission_for(Current.user).in?([ :owner, :full_control ])
    end

    # Resolve only this account's wallet within the current family's connection.
    def set_wallet
      @wallet = @account.bitcoin_wallet_account
      raise ActiveRecord::RecordNotFound unless @wallet && @wallet.onchain_wallet_item.family_id == Current.family.id
    end

    # Keep what the user typed so a validation error never forces them to start
    # over. Source field errors show beside the inputs; any other error stays in the alert.
    def keep_failed_source(error)
      @form_values = params.fetch(:source, {}).permit(:address_or_key, :receive_address, :gap_limit).to_h.symbolize_keys
      @field_errors = error.record.errors if error.record.is_a?(BitcoinWalletSource)
      @error_message = error.record.errors
        .reject { |item| @field_errors && item.attribute.in?(SOURCE_FIELDS) }
        .map(&:full_message).to_sentence.presence
    end

    # Accept one pasted value and infer its kind: an account-level xpub/zpub is
    # an HD source verified by a receive address; anything else is an address.
    # The field name ends in _key so request logs filter it.
    def source_params
      input = params.require(:source).permit(:address_or_key, :receive_address, :gap_limit)
      key = input[:address_or_key].to_s.strip
      if key.match?(/\A[xz]pub/)
        { kind: "bip84", extended_public_key: key, receive_address: input[:receive_address],
          gap_limit: input[:gap_limit].presence || 20 }
      else
        { kind: "address", receive_address: key }
      end
    end

    # Find existing BTC-like positions in this account, avoiding a separate
    # canonical security that would duplicate its manually tracked quantity.
    def bitcoin_securities
      ids = @account.holdings.distinct.pluck(:security_id) + @account.trades.distinct.pluck(:security_id)
      Security.where(id: ids.uniq).select { |security| security.ticker.to_s.upcase.match?(/\A(?:CRYPTO:)?(?:BTC|XBT)(?:-?USD)?\z/) }
    end

    # Require a choice from this account's BTC positions, or resolve Bitcoin
    # when no such position exists. Creation runs inside the draft transaction.
    def selected_security
      securities = bitcoin_securities
      if securities.empty?
        Onchain::SecurityResolver.resolve(symbol: "BTC", name: "Bitcoin")
      else
        securities.find { |security| security.id == params.dig(:source, :security_id) } || raise(ActiveRecord::RecordNotFound)
      end
    end
end
