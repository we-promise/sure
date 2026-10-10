module StreamExtensions
  extend ActiveSupport::Concern

  COMPACT_VIEW_CONTEXTS = %w[account global].freeze
  FILTERED_REFERER_PATTERN = /q\[|search=|categories|merchants|tags|types|amount|status|start_date|end_date/.freeze

  def stream_redirect_to(path, notice: nil, alert: nil)
    custom_stream_redirect(path, notice: notice, alert: alert)
  end

  def stream_redirect_back_or_to(path, notice: nil, alert: nil)
    custom_stream_redirect(path, redirect_back: true, notice: notice, alert: alert)
  end

  # Explicit row-render context for compact turbo-stream replaces.
  # `view_ctx` is allowlisted ("account"/"global"); `is_filtered` distinguishes
  # an explicitly supplied false (key present) from a missing value (key
  # absent → referer fallback). Drawers (#show hidden fields) and updates
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

  private
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

    def custom_stream_redirect(path, redirect_back: false, notice: nil, alert: nil)
      flash[:notice] = notice if notice.present?
      flash[:alert] = alert if alert.present?

      redirect_target_url = redirect_back ? request.referer : path
      render turbo_stream: turbo_stream.action(:redirect, redirect_target_url)
    end
end
