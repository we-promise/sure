# frozen_string_literal: true

# Divides what the member paid for a Tricount entry into parts, one per card
# or bank charge (TricountAccount#split_payment!). It looks and works like
# splitting a transaction (SplitsController): a payment row's drawer opens the
# same split dialog, and a part's row offers to edit or undo the split. The
# parts are kept on the tricount, not as child entries, because each sync
# rebuilds the account's rows from Tricount.
class TricountPaymentSplitsController < ApplicationController
  before_action :set_payment_split
  before_action :require_write_permission!

  def new
    redirect_to edit_tricount_payment_split_path(@payment_split.entry) if @payment_split.split?
  end

  def edit
    redirect_to new_tricount_payment_split_path(@payment_split.entry) unless @payment_split.split?
  end

  def update
    @payment_split.tricount_account.split_payment!(@payment_split.entry_uuid, submitted_parts)
    redirect_to account_path(@payment_split.entry.account), notice: t("tricount_items.payment_split.saved")
  rescue TricountAccount::InvalidPaymentSplit
    redirect_to account_path(@payment_split.entry.account),
      alert: t("tricount_items.payment_split.invalid", total: @payment_split.total.format)
  end

  def destroy
    @payment_split.tricount_account.remove_payment_split!(@payment_split.entry_uuid)
    redirect_to account_path(@payment_split.entry.account), notice: t("tricount_items.payment_split.removed")
  end

  private

    def set_payment_split
      entry = Current.family.entries.joins(:account).merge(Account.accessible_by(Current.user)).find(params[:entry_id])
      @payment_split = TricountAccount::PaymentSplit.for(entry)
      raise ActiveRecord::RecordNotFound unless @payment_split
    end

    def require_write_permission!
      require_account_permission!(@payment_split.entry.account, :write, redirect_path: transaction_path(@payment_split.entry))
    end

    # The dialog's rows (split[splits][<index>][amount]), in the order shown.
    def submitted_parts
      rows = params.fetch(:split, {}).fetch(:splits, {})
      rows = rows.to_unsafe_h if rows.respond_to?(:to_unsafe_h)
      rows.values.map { |row| row.is_a?(Hash) ? row["amount"] : nil }
    end
end
