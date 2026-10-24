class ValuationsController < ApplicationController
  include EntryableResource, StreamExtensions

  def new
    super
    ensure_manual_entries_supported!(@entry.account) if @entry.account
  end

  def confirm_create
    @account = accessible_accounts.find(params.dig(:entry, :account_id))
    ensure_manual_entries_supported!(@account)
    return unless require_account_permission!(@account)

    @entry = @account.entries.build(entry_params.merge(currency: @account.currency))

    if entry_params[:amount].blank?
      @error_message = t("valuations.errors.amount_required")
      render :new, status: :unprocessable_entity
      return
    end

    @reconciliation_dry_run = @entry.account.create_reconciliation(
      balance: entry_params[:amount],
      date: entry_params[:date],
      dry_run: true
    )

    render :confirm_create
  end

  def confirm_update
    @entry = Current.accessible_entries.find(params[:id])
    ensure_manual_entries_supported!(@entry.account)
    return unless require_account_permission!(@entry.account)

    @account = @entry.account

    if entry_params[:amount].blank?
      @error_message = t("valuations.errors.amount_required")
      render :show, status: :unprocessable_entity
      return
    end

    @entry.assign_attributes(entry_params.merge(currency: @account.currency))

    @reconciliation_dry_run = @entry.account.update_reconciliation(
      @entry,
      balance: entry_params[:amount],
      date: entry_params[:date],
      dry_run: true
    )

    render :confirm_update
  end

  def create
    account = accessible_accounts.find(params.dig(:entry, :account_id))
    ensure_manual_entries_supported!(account)
    return unless require_account_permission!(account)

    result = account.create_reconciliation(
      balance: entry_params[:amount],
      date: entry_params[:date],
    )

    if result.success?
      respond_to do |format|
        format.html { redirect_back_or_to account_path(account), notice: t(".account_updated") }
        format.turbo_stream { stream_redirect_back_or_to(account_path(account), notice: t(".account_updated")) }
      end
    else
      @error_message = result.error_message
      render :new, status: :unprocessable_entity
    end
  end

  def update
    ensure_manual_entries_supported!(@entry.account)
    return unless require_account_permission!(@entry.account)

    # Notes updating is independent of reconciliation, just a simple CRUD operation
    @entry.update!(notes: entry_params[:notes]) if entry_params[:notes].present?

    if entry_params[:date].present? && entry_params[:amount].present?
      result = @entry.account.update_reconciliation(
        @entry,
        balance: entry_params[:amount],
        date: entry_params[:date],
      )
    end

    if result.nil? || result.success?
      @entry.reload

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), notice: t(".entry_updated") }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              dom_id(@entry, :header),
              partial: "valuations/header",
              locals: { entry: @entry }
            ),
            turbo_stream.replace(@entry)
          ]
        end
      end
    else
      @error_message = result.error_message
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    ensure_manual_entries_supported!(@entry.account)
    super
  end

  private
    def ensure_manual_entries_supported!(account)
      raise ActiveRecord::RecordNotFound unless account.supports_manual_entries?
    end

    def entry_params
      params.require(:entry).permit(:date, :amount, :notes)
    end
end
