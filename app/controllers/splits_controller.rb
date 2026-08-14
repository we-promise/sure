class SplitsController < ApplicationController
  before_action :set_entry
  before_action :require_split_write_permission!, only: %i[create update destroy]

  def new
    @categories = Current.family.categories.alphabetically
    @merchants = Current.family.available_merchants_for(Current.user).alphabetically
    @tags = Current.family.tags.alphabetically
  end

  def create
    unless @entry.transaction.splittable?
      redirect_back_or_to transactions_path, alert: t("splits.create.not_splittable")
      return
    end

    splits = build_splits(split_params[:splits])

    @entry.split!(splits)
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

    @categories = Current.family.categories.alphabetically
    @merchants = Current.family.available_merchants_for(Current.user).alphabetically
    @tags = Current.family.tags.alphabetically
    @children = @entry.child_entries.includes(:entryable)
  end

  def update
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    splits = build_splits(split_params[:splits])

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

    # Maps raw split params into `Entry#split!` input, scoping merchant_id and
    # tag_ids to the current family so a crafted request can't attribute a
    # split to another family's merchant or tag.
    def build_splits(raw_splits)
      raw_splits = raw_splits.values if raw_splits.respond_to?(:values)
      family_merchant_ids = Current.family.available_merchants_for(Current.user).ids.map(&:to_s)

      raw_splits.map do |s|
        tag_ids = Current.family.tags.where(id: Array(s[:tag_ids]).reject(&:blank?)).ids
        merchant_id = s[:merchant_id].presence
        merchant_id = nil unless family_merchant_ids.include?(merchant_id.to_s)

        {
          name: s[:name],
          amount: s[:amount].to_d * -1,
          category_id: s[:category_id].presence,
          merchant_id: merchant_id,
          tag_ids: tag_ids,
          excluded: s[:excluded]
        }
      end
    end
end
