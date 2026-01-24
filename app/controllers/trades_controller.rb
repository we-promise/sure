class TradesController < ApplicationController
  include EntryableResource

  before_action :set_entry_for_unlock, only: :unlock

  # Defaults to a buy trade
  def new
    @account = Current.family.accounts.find_by(id: params[:account_id])
    @model = Current.family.entries.new(
      account: @account,
      currency: @account ? @account.currency : Current.family.currency,
      entryable: Trade.new
    )
  end

  # Can create a trade, transaction (e.g. "fees"), or transfer (e.g. "withdrawal")
  def create
    @account = Current.family.accounts.find(params[:account_id])
    @model = Trade::CreateForm.new(create_params.merge(account: @account)).create

    if @model.persisted?
      # Mark manually created entries as user-modified to protect from sync
      if @model.is_a?(Entry)
        @model.lock_saved_attributes!
        @model.mark_user_modified!
      end

      flash[:notice] = t("entries.create.success")

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@account) }
        format.turbo_stream { stream_redirect_back_or_to account_path(@account) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @entry.update(update_entry_params)
      @entry.lock_saved_attributes!
      @entry.mark_user_modified!
      @entry.sync_account_later

      # Reload to ensure fresh state for turbo stream rendering
      @entry.reload

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), notice: t("entries.update.success") }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              dom_id(@entry, :header),
              partial: "trades/header",
              locals: { entry: @entry }
            ),
            turbo_stream.replace(
              dom_id(@entry, :protection),
              partial: "entries/protection_indicator",
              locals: { entry: @entry, unlock_path: unlock_trade_path(@entry.trade) }
            ),
            turbo_stream.replace(@entry)
          ]
        end
      end
    else
      render :show, status: :unprocessable_entity
    end
  end

  def unlock
    @entry.unlock_for_sync!
    flash[:notice] = t("entries.unlock.success")

    redirect_back_or_to account_path(@entry.account)
  end

  private
    def set_entry_for_unlock
      trade = Current.family.trades.find(params[:id])
      @entry = trade.entry
    end

    def entry_params
      params.require(:entry).permit(
        :name, :date, :amount, :currency, :excluded, :notes, :nature,
        entryable_attributes: [ :id, :qty, :price, :investment_activity_label ]
      )
    end

    def create_params
      params.require(:model).permit(
        :date, :amount, :currency, :qty, :price, :ticker, :manual_ticker, :type, :transfer_account_id
      )
    end

    def update_entry_params
      return entry_params unless entry_params[:entryable_attributes].present?

      update_params = entry_params
      update_params = update_params.merge(entryable_type: "Trade")

      qty = update_params[:entryable_attributes][:qty]
      price = update_params[:entryable_attributes][:price]
      nature = update_params[:nature]

      if qty.present? && price.present?
        is_sell = nature == "inflow"
        qty = is_sell ? -qty.to_d.abs : qty.to_d.abs
        update_params[:entryable_attributes][:qty] = qty
        update_params[:amount] = qty * price.to_d

        # Sync investment_activity_label with Buy/Sell type if not explicitly set to something else
        # Check both the submitted param and the existing record's label
        current_label = update_params[:entryable_attributes][:investment_activity_label].presence ||
                        @entry.trade&.investment_activity_label
        if current_label.blank? || current_label == "Buy" || current_label == "Sell"
          update_params[:entryable_attributes][:investment_activity_label] = is_sell ? "Sell" : "Buy"
        end

        # Update entry name to reflect Buy/Sell change
        ticker = @entry.trade&.security&.ticker
        if ticker.present?
          update_params[:name] = Trade.build_name(is_sell ? "sell" : "buy", qty.abs, ticker)
        end
      end

      update_params.except(:nature)
    end
end
