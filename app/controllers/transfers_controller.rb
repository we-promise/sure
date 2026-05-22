class TransfersController < ApplicationController
  include StreamExtensions

  before_action :set_transfer, only: %i[show destroy update mark_as_recurring]
  before_action :set_accounts, only: %i[new create]

  def new
    @transfer = Transfer.new
    @from_account_id = params[:from_account_id]
  end

  def show
    @categories = Current.family.categories.alphabetically

    # Whether the current user can hit `mark_as_recurring`: feature flag on,
    # AND they have write access to BOTH transfer endpoints. Gating the
    # view button on this avoids showing a CTA that the controller would
    # reject via `require_account_permission!` for read-only sharers.
    endpoint_ids = [ @transfer.from_account&.id, @transfer.to_account&.id ].compact
    writable_endpoint_count = Account.writable_by(Current.user).where(id: endpoint_ids).distinct.count
    @can_mark_as_recurring_transfer =
      !Current.family.recurring_transactions_disabled? &&
      endpoint_ids.size == 2 &&
      writable_endpoint_count == 2
  end

  def create
    # Validate user has write access to both accounts
    source_account = accessible_accounts.find(transfer_params[:from_account_id])
    destination_account = accessible_accounts.find(transfer_params[:to_account_id])

    return unless require_account_permission!(source_account, redirect_path: transactions_path)
    return unless require_account_permission!(destination_account, redirect_path: transactions_path)

    @transfer = Transfer::Creator.new(
      family: Current.family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: transfer_params[:date].present? ? Date.parse(transfer_params[:date]) : Date.current,
      amount: transfer_params[:amount].to_d,
      exchange_rate: transfer_params[:exchange_rate].presence&.to_d
    ).create

    if @transfer.persisted?
      success_message = "Transfer created"
      respond_to do |format|
        format.html { redirect_back_or_to transactions_path, notice: success_message }
        format.turbo_stream { stream_redirect_back_or_to transactions_path, notice: success_message }
      end
    else
      @from_account_id = transfer_params[:from_account_id]
      render :new, status: :unprocessable_entity
    end
  rescue Money::ConversionError
    @transfer ||= Transfer.new
    @transfer.errors.add(:base, "Exchange rate unavailable for selected currencies and date")
    set_accounts
    render :new, status: :unprocessable_entity
  rescue ArgumentError
    @transfer ||= Transfer.new
    @transfer.errors.add(:date, "is invalid")
    set_accounts
    render :new, status: :unprocessable_entity
  end

  def update
    outflow_account = @transfer.outflow_transaction.entry.account
    return unless require_account_permission!(outflow_account, redirect_path: transactions_url)

    Transfer.transaction do
      update_transfer_status
      update_transfer_details unless transfer_update_params[:status] == "rejected"
    end

    respond_to do |format|
      format.html { redirect_back_or_to transactions_url, notice: t(".success") }
      format.turbo_stream
    end
  end

  def destroy
    outflow_account = @transfer.outflow_transaction.entry.account
    return unless require_account_permission!(outflow_account, redirect_path: transactions_url)

    @transfer.destroy!
    redirect_back_or_to transactions_url, notice: t(".success")
  end

  def mark_as_recurring
    if Current.family.recurring_transactions_disabled?
      flash[:alert] = t("recurring_transactions.transfer_feature_disabled")
      redirect_back_or_to transactions_path
      return
    end

    source_account      = @transfer.from_account
    destination_account = @transfer.to_account

    if source_account.nil? || destination_account.nil?
      flash[:alert] = t("recurring_transactions.unexpected_error")
      redirect_back_or_to transactions_path
      return
    end

    return unless require_account_permission!(source_account)
    return unless require_account_permission!(destination_account)

    existing = Current.family.recurring_transactions.find_by(
      account_id: source_account.id,
      destination_account_id: destination_account.id,
      amount: @transfer.outflow_transaction.entry.amount,
      currency: @transfer.outflow_transaction.entry.currency
    )

    if existing
      flash[:alert] = t("recurring_transactions.transfer_already_exists")
      respond_to do |format|
        format.html { redirect_back_or_to transactions_path }
      end
      return
    end

    begin
      RecurringTransaction.create_from_transfer(@transfer)
      flash[:notice] = t("recurring_transactions.transfer_marked_as_recurring")
      respond_to do |format|
        format.html { redirect_back_or_to transactions_path }
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # RecordNotUnique covers the race window between `find_by` and `create!`
      # (the partial unique index protects us at the DB level).
      flash[:alert] = t("recurring_transactions.transfer_creation_failed")
      respond_to do |format|
        format.html { redirect_back_or_to transactions_path }
      end
    rescue StandardError => e
      Rails.logger.error(
        "transfers#mark_as_recurring failed: #{e.class} #{e.message} " \
        "(transfer=#{@transfer&.id} family=#{Current.family&.id} user=#{Current.user&.id})"
      )
      flash[:alert] = t("recurring_transactions.unexpected_error")
      respond_to do |format|
        format.html { redirect_back_or_to transactions_path }
      end
    end
  end

  private
    def set_transfer
      # Finds the transfer and ensures the user has access to it
      accessible_transaction_ids = Current.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(Current.user))
        .select(:id)

      @transfer = Transfer
                    .where(id: params[:id])
                    .where(inflow_transaction_id: accessible_transaction_ids)
                    .first!
    end

    def transfer_params
      params.require(:transfer).permit(:from_account_id, :to_account_id, :amount, :date, :name, :excluded, :exchange_rate)
    end

    def set_accounts
      @accounts = accessible_accounts
        .alphabetically
        .includes(
          :account_providers,
          logo_attachment: :blob
        )
    end

    def transfer_update_params
      params.require(:transfer).permit(:notes, :status, :category_id)
    end

    def update_transfer_status
      if transfer_update_params[:status] == "rejected"
        @transfer.reject!
      elsif transfer_update_params[:status] == "confirmed"
        @transfer.confirm!
      end
    end

    def update_transfer_details
      @transfer.outflow_transaction.update!(category_id: transfer_update_params[:category_id])
      @transfer.update!(notes: transfer_update_params[:notes])
    end
end
