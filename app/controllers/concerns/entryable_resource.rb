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
    unless can_edit_entry?
      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), alert: t("accounts.not_authorized") }
        format.turbo_stream { stream_redirect_back_or_to(account_path(@entry.account), alert: t("accounts.not_authorized")) }
      end
      return
    end

    @entry.destroy!
    @entry.sync_account_later

    redirect_back_or_to account_path(@entry.account), notice: t("account.entries.destroy.success")
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
