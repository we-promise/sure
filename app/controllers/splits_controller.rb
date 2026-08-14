class SplitsController < ApplicationController
  before_action :set_entry
  before_action :require_split_write_permission!, only: %i[create update destroy]

  def new
    set_form_options
  end

  def create
    unless @entry.transaction.splittable?
      redirect_back_or_to transactions_path, alert: t("splits.create.not_splittable")
      return
    end

    @entry.split!(build_splits)
    @entry.sync_account_later

    redirect_back_or_to transactions_path, notice: t("splits.create.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_back_or_to transactions_path, alert: e.message
  end

  def edit
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    set_form_options
    @children = @entry.child_entries.includes(entryable: :tags)
  end

  def update
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    splits = build_splits

    Entry.transaction do
      @entry.unsplit!
      @entry.split!(splits)
    end

    @entry.sync_account_later

    redirect_to transactions_path, notice: t("splits.update.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to transactions_path, alert: e.message
  end

  def destroy
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    @entry.unsplit!
    @entry.sync_account_later

    redirect_to transactions_path, notice: t("splits.destroy.success")
  end

  private

    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def require_split_write_permission!
      require_account_permission!(@entry.account, redirect_path: transactions_path)
    end

    def resolve_to_parent!
      @entry = @entry.parent_entry if @entry.split_child?
    end

    def split_params
      params.require(:split).permit(splits: [ :name, :amount, :category_id, :merchant_id, :excluded, tag_ids: [] ])
    end

    def set_form_options
      @categories = Current.family.categories.alphabetically
      @merchants = Current.family.available_merchants_for(Current.user).alphabetically
      @tags = Current.family.tags.alphabetically
    end

    # Builds Entry#split! input from submitted params, re-scoping category/merchant/tag ids
    # against the current family rather than trusting the submitted ids directly — mirrors
    # Rule::ActionExecutor::SplitTransaction#build_splits, which applies the same defense for
    # rule-driven splits. Without this, a crafted request could attach another family's
    # category, merchant, or tag to one of the user's own transactions.
    def build_splits
      family_category_ids = Current.family.categories.pluck(:id).to_set
      family_merchant_ids = Current.family.available_merchants_for(Current.user).pluck(:id).to_set
      family_tag_ids = Current.family.tags.pluck(:id).to_set

      raw_splits = split_params[:splits]
      raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

      raw_splits.map do |s|
        category_id = s[:category_id].presence
        category_id = nil unless category_id && family_category_ids.include?(category_id)

        merchant_id = s[:merchant_id].presence
        merchant_id = nil unless merchant_id && family_merchant_ids.include?(merchant_id)

        tag_ids = Array(s[:tag_ids]).reject(&:blank?) & family_tag_ids.to_a

        {
          name: s[:name],
          amount: s[:amount].to_d * -1,
          category_id: category_id,
          merchant_id: merchant_id,
          tag_ids: tag_ids,
          excluded: s[:excluded]
        }
      end
    end
end
