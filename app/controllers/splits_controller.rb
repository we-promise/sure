class SplitsController < ApplicationController
  before_action :set_entry

  def new
    @categories = Current.family.categories.alphabetically
  end

  def create
    raw_splits = split_params[:splits]
    raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

    splits = raw_splits.map do |s|
      { name: s[:name], amount: s[:amount].to_d * -1, category_id: s[:category_id].presence }
    end

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
    @children = @entry.child_entries.includes(:entryable)
  end

  def update
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    raw_splits = split_params[:splits]
    raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

    splits = raw_splits.map do |s|
      { name: s[:name], amount: s[:amount].to_d * -1, category_id: s[:category_id].presence }
    end

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

    @entry.unsplit!
    @entry.sync_account_later

    redirect_to transactions_path, notice: t("splits.destroy.success")
  end

  private

    def set_entry
      @entry = Current.family.entries.find(params[:transaction_id])
    end

    def resolve_to_parent!
      @entry = @entry.parent_entry if @entry.split_child?
    end

    def split_params
      params.require(:split).permit(splits: [ :name, :amount, :category_id ])
    end
end
