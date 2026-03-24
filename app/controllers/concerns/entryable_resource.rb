module EntryableResource
  extend ActiveSupport::Concern

  included do
    include StreamExtensions, ActionView::RecordIdentifier

    before_action :set_entry, only: %i[show update destroy]
  end

  def show
  end

  def new
    account = Current.family.accounts.find_by(id: params[:account_id])

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
    account = @entry.account
    permission = account.permission_for(Current.user)

    unless permission.in?([ :owner, :full_control ])
      redirect_back_or_to account_path(account), alert: t("accounts.not_authorized")
      return
    end

    @entry.destroy!
    @entry.sync_account_later

    redirect_back_or_to account_path(account), notice: t("account.entries.destroy.success")
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
end
