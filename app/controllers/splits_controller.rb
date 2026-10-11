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
      @categories = grouped_categories
      @merchants = Current.family.available_merchants_for(Current.user).alphabetically
      @tags = Current.family.tags.alphabetically
    end

    # Builds Entry#split! input from submitted params. Category, merchant and tag ids are
    # re-scoped to the current family (Entry::SplitReferences, shared with rule-driven splits)
    # rather than trusted, so a crafted request can't attach another family's records.
    def build_splits
      references = Entry::SplitReferences.new(Current.family, merchants: Current.family.available_merchants_for(Current.user))

      raw_splits = split_params[:splits] || []
      raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

      raw_splits.map do |s|
        {
          name: s[:name],
          amount: s[:amount].to_d * -1,
          excluded: s[:excluded],
          **references.scope(category_id: s[:category_id], merchant_id: s[:merchant_id], tag_ids: s[:tag_ids])
        }
      end
    end

    def grouped_categories
      Current.family.categories.alphabetically_by_hierarchy
    end
end
