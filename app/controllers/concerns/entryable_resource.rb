module EntryableResource
  extend ActiveSupport::Concern

  COMPACT_VIEW_CONTEXTS = %w[account global].freeze
  FILTERED_REFERER_PATTERN = /q\[|search=|categories|merchants|tags|types|amount|status|start_date|end_date/.freeze

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

    # Explicit row-render context for compact turbo-stream replaces.
    # `view_ctx` is allowlisted ("account"/"global"); `is_filtered` distinguishes
    # an explicitly supplied false (key present) from a missing value (key
    # absent → referer fallback). Both #show (drawer hidden fields) and #update
    # resolve through here so the two paths cannot disagree.
    def assign_compact_row_context
      @view_ctx, @is_filtered = resolve_compact_row_context
    end

    def resolve_compact_row_context
      view_ctx = params[:view_ctx].presence_in(COMPACT_VIEW_CONTEXTS) ||
        fallback_view_ctx_from_referer || "global"

      is_filtered = if params.key?(:is_filtered)
        ActiveModel::Type::Boolean.new.cast(params[:is_filtered])
      else
        fallback_filtered_from_referer
      end

      [ view_ctx, is_filtered ]
    end

    # Legacy fallback for callers that do not (yet) send explicit params:
    # direct PATCH links, bookmarks, and the quick-edit badge before it was
    # updated. Params win whenever present.
    def fallback_view_ctx_from_referer
      referer = request.referer
      return nil if referer.blank?

      referer.include?("/accounts/") ? "account" : "global"
    end

    def fallback_filtered_from_referer
      !!request.referer&.match?(FILTERED_REFERER_PATTERN)
    end
end
