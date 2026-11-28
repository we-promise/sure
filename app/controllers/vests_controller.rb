# One screen for an RSU vest and the income and tax entries recorded with it
# (Trade::VestForm). Opening any of those entries lands here.
class VestsController < ApplicationController
  before_action :set_vest, only: %i[show update destroy]

  def new
    @account = accessible_accounts.find(params[:account_id])
    @form = Trade::VestForm.new(account: @account, date: Date.current)
  end

  def create
    @account = accessible_accounts.find(params[:account_id])
    return unless require_account_permission!(@account)

    @form = Trade::VestForm.new(account: @account, **vest_params.to_h.symbolize_keys)

    if @form.save
      flash[:notice] = t(".success")
      respond_to do |format|
        format.html { redirect_back_or_to account_path(@account) }
        format.turbo_stream { stream_redirect_back_or_to account_path(@account) }
      end
    else
      render :new, status: :unprocessable_entity, formats: [ :html ]
    end
  end

  def show
    @form = Trade::VestForm.for(@entry)
  end

  def update
    return unless require_account_permission!(@entry.account)

    @form = Trade::VestForm.for(@entry)
    @form.assign_attributes(vest_params.except(:ticker, :manual_ticker).to_h.symbolize_keys)

    if @form.save
      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), notice: t(".success") }
        format.turbo_stream { stream_redirect_back_or_to account_path(@entry.account), notice: t(".success") }
      end
    else
      render :show, status: :unprocessable_entity, formats: [ :html ]
    end
  end

  def destroy
    return unless require_account_permission!(@entry.account)

    @entry.destroy_unless_split_part_transferred!
    @entry.sync_account_later

    redirect_back_or_to account_path(@entry.account), notice: t(".success")
  rescue Entry::SplitPartTransferredError
    redirect_back_or_to account_path(@entry.account), alert: t(".part_transferred")
  end

  private
    def set_vest
      @entry = Current.family.entries
                 .joins(:account)
                 .merge(Account.accessible_by(Current.user))
                 .find(params[:id])
      raise ActiveRecord::RecordNotFound unless @entry.trade? && @entry.trade.vest?
    end

    def vest_params
      params.require(:vest).permit(
        :date, :ticker, :manual_ticker, :vested_qty, :units_withheld, :price, :income_category_id,
        :sold_qty, :sold_price, :sold_fee,
        tax_lines: [ :id, :name, :category_id, :amount ]
      )
    end
end
