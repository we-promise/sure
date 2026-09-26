module EntryableResource
  extend ActiveSupport::Concern

  included do
    include StreamExtensions, ActionView::RecordIdentifier

    before_action :set_entry, only: %i[show update destroy]

    helper_method :can_edit_entry?, :can_annotate_entry?
  end

  def show
  end

  def new
    account = accessible_accounts.find_by(id: params[:account_id])

    @entry = Current.family.entries.new(
      account: account,
      currency: account ? account.currency : Current.family.currency,
      entryable: entryable
    )
  end

  def create
    raise NotImplementedError, "Entryable resources must implement #create"
  end

  def update
    raise NotImplementedError, "Entryable resources must implement #update"
  end

  def destroy
    return unless require_account_permission!(@entry.account)

    @entry.destroy!
    @entry.sync_account_later

    redirect_back_or_to account_path(@entry.account), notice: t("account.entries.destroy.success")
  rescue ActiveRecord::RecordNotDestroyed => e
    # Entry's before_destroy guards (EMI purchase/installment, split child)
    # throw :abort with a message in errors[:base] instead of letting the
    # record actually delete. Surface that message instead of a 500 — the
    # view is expected to hide the delete action for these cases, but this
    # is the backstop for any path that reaches here anyway (bulk actions,
    # API, a stale page).
    redirect_back_or_to account_path(@entry.account), alert: e.record.errors[:base].first || t("entries.destroy.failure")
  end

  private
    def entryable
      controller_name.classify.constantize.new
    end

    def set_entry
      @entry = Current.family.entries
                 .joins(:account)
                 .merge(Account.accessible_by(Current.user))
                 .find(params[:id])
    end

    def entry_permission
      @entry_permission ||= @entry&.account&.permission_for(Current.user)
    end

    def can_edit_entry?
      entry_permission.in?([ :owner, :full_control ])
    end

    def can_annotate_entry?
      entry_permission.in?([ :owner, :full_control, :read_write ])
    end
end
