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

  def destroy
    @entry.unsplit!
    @entry.sync_account_later

    redirect_back_or_to transactions_path, notice: t("splits.destroy.success")
  end

  private

    def set_entry
      @entry = Current.family.entries.find(params[:transaction_id])
    end

    def split_params
      params.require(:split).permit(splits: [ :name, :amount, :category_id ])
    end
end
