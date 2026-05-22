class TransactionCategoriesController < ApplicationController
  include ActionView::RecordIdentifier

  def update
    @entry = Current.accessible_entries.transactions.find(params[:transaction_id])
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    @entry.update!(entry_params)

    transaction = @entry.transaction

    if needs_rule_notification?(transaction)
      flash[:cta] = {
        type: "category_rule",
        category_id: transaction.category_id,
        category_name: transaction.category.name,
        merchant_name: @entry.name
      }
    end

    transaction.lock_saved_attributes!
    @entry.lock_saved_attributes!

    in_split_group = helpers.in_split_group?(@entry, params[:grouped])
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@entry) }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            dom_id(transaction, "category_menu_mobile"),
            partial: "transactions/transaction_category",
            locals: { transaction: transaction, variant: "mobile", in_split_group: in_split_group }
          ),
          turbo_stream.replace(
            dom_id(transaction, "category_menu_desktop"),
            partial: "transactions/transaction_category",
            locals: { transaction: transaction, variant: "desktop", in_split_group: in_split_group }
          ),
          turbo_stream.replace(
            "category_name_mobile_#{transaction.id}",
            partial: "categories/category_name_mobile",
            locals: { transaction: transaction }
          ),
          *flash_notification_stream_items
        ]
      end
    end
  end

  private
    def entry_params
      params.require(:entry).permit(:entryable_type, entryable_attributes: [ :id, :category_id ])
    end

    def needs_rule_notification?(transaction)
      return false if Current.user.rule_prompts_disabled

      if Current.user.rule_prompt_dismissed_at.present?
        time_since_last_rule_prompt = Time.current - Current.user.rule_prompt_dismissed_at
        return false if time_since_last_rule_prompt < 1.day
      end

      transaction.saved_change_to_category_id? &&
      transaction.eligible_for_category_rule?
    end
end
