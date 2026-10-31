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

    # A rule run, an API request or a double submit can split it between the check above and
    # here; split_once! re-checks under a lock.
    unless @entry.split_once!(build_splits)
      redirect_back_or_to transactions_path, alert: t("splits.create.not_splittable")
      return
    end
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
    # In the order the rows were entered; without an ORDER BY a rewritten row can move.
    @children = @entry.child_entries.order(:created_at, :id).includes(entryable: :tags)
  end

  def update
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    splits = build_splits

    # A concurrent unsplit or edit can land between the check above and here.
    unless @entry.resplit!(splits)
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
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

    unless @entry.unsplit_once!
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end
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
      @merchants = Current.family.available_merchants_for(Current.user).with_attached_logo.alphabetically
      @tags = Current.family.tags.alphabetically
    end

    # Builds Entry#split! input from submitted params. Category, merchant and tag ids are
    # re-scoped to the current family (Entry::SplitReferences, shared with rule-driven splits)
    # rather than trusted, so a crafted request can't attach another family's records.
    def build_splits
      references = Entry::SplitReferences.for_user(Current.family, Current.user)

      raw_splits = split_params[:splits] || []
      raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

      raw_splits.map do |s|
        # A blank merchant follows the parent's; a picked merchant or "no merchant" is the row's own.
        no_merchant = s[:merchant_id] == SplitsHelper::NO_MERCHANT
        scoped = references.scope(category_id: s[:category_id], merchant_id: (s[:merchant_id] unless no_merchant), tag_ids: s[:tag_ids])

        {
          name: s[:name],
          amount: s[:amount].to_d * -1,
          excluded: s[:excluded],
          own_merchant: no_merchant || scoped[:merchant_id].present?,
          **scoped
        }
      end
    end

    def grouped_categories
      Current.family.categories.alphabetically_by_hierarchy
    end
end
