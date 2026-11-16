module EntryableResource
  extend ActiveSupport::Concern

  # Compact row-render context (COMPACT_VIEW_CONTEXTS,
  # FILTERED_REFERER_PATTERN, assign/resolve_compact_row_context and the
  # referer fallbacks) lives in StreamExtensions so controllers that cannot
  # include this concern (e.g. TransfersController, which owns set_transfer)
  # resolve drawer/update row context the same way.
  # Kept here as aliases so existing references keep working.
  COMPACT_VIEW_CONTEXTS = StreamExtensions::COMPACT_VIEW_CONTEXTS
  FILTERED_REFERER_PATTERN = StreamExtensions::FILTERED_REFERER_PATTERN

  included do
    include StreamExtensions, ActionView::RecordIdentifier

    before_action :set_entry, only: %i[show update destroy]
    before_action :assign_compact_row_context, only: :show

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
