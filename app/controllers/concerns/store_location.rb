module StoreLocation
  extend ActiveSupport::Concern

  # The session lives in a 4 KB cookie, so a long filtered URL (e.g. the
  # transactions list filtered by dozens of accounts) would raise
  # CookieOverflow. Past this size only the path is kept, without the query.
  MAX_STORED_RETURN_TO_BYTES = 1024

  included do
    helper_method :previous_path
    before_action :store_return_to
    after_action :clear_previous_path

    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found
  end

  def previous_path
    session[:return_to] || fallback_path
  end

private
  def handle_not_found
    if request.fullpath == session[:return_to]
      session.delete(:return_to)
      redirect_to fallback_path
    else
      head :not_found
    end
  end

  def store_return_to
    safe = safe_return_to(params[:return_to])
    return unless safe

    safe = safe.split("?", 2).first if safe.bytesize > MAX_STORED_RETURN_TO_BYTES
    if safe.bytesize <= MAX_STORED_RETURN_TO_BYTES
      session[:return_to] = safe
    else
      # Don't leave an older target behind for previous_path to return.
      session.delete(:return_to)
    end
  end

  # Only allow internal absolute paths (a single leading "/"). Blocks absolute
  # URLs, protocol-relative ("//evil"), and backslash tricks ("/\\evil") so a
  # crafted ?return_to= can't open-redirect — including via a custom
  # turbo_stream redirect, which Rails' redirect host-guard does NOT cover
  # (the client `Turbo.visit`es the target and full-navigates cross-origin).
  def safe_return_to(value)
    # is_a?(String) first: a crafted `?return_to[]=foo` makes params[:return_to]
    # an Array, and Array#match? doesn't exist — without this guard the helper
    # raises NoMethodError before the redirect hardening can reject it.
    value if value.is_a?(String) && value.present? && value.match?(%r{\A/(?![/\\])})
  end

  def clear_previous_path
    if request.fullpath == session[:return_to]
      session.delete(:return_to)
    end
  end

  def fallback_path
    root_path
  end
end
