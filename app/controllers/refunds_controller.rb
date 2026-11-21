class RefundsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_entry
  before_action :require_refund_write_permission!

  def new
    @search = params[:search] if params[:search].is_a?(String)
    @purchases = Transaction::RefundablePurchases.new(
      entries: Current.accessible_entries,
      search: @search
    ).call
    linked_purchase = @entry.transaction.refund_of&.entry
    if linked_purchase && Current.accessible_entries.exists?(id: linked_purchase.id)
      @selected_purchase_id = linked_purchase.id
      @purchases.unshift(linked_purchase) unless @purchases.any? { |purchase| purchase.id == linked_purchase.id }
    end
  end

  def create
    purchase_id = params.require(:refund).permit(:purchase_entry_id)[:purchase_entry_id].presence
    purchase = Current.accessible_entries.where(entryable_type: "Transaction").find(purchase_id).transaction if purchase_id
    @entry.transaction.mark_as_refund!(purchase: purchase)
    redirect_to transaction_path(@entry), notice: t("refunds.saved"), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to transaction_path(@entry), alert: error.record.errors.full_messages.to_sentence, status: :see_other
  end

  def destroy
    @entry.transaction.clear_refund! if @entry.transaction.refund?
    redirect_to transaction_path(@entry), notice: t("refunds.cleared"), status: :see_other
  end

  private
    def set_entry
      @entry = Current.accessible_entries.where(entryable_type: "Transaction").find(params[:transaction_id])
    end

    def require_refund_write_permission!
      require_account_permission!(@entry.account, redirect_path: transactions_path)
    end
end
