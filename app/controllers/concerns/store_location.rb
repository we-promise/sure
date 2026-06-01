module StoreLocation
  extend ActiveSupport::Concern

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
    session[:return_to] = safe if safe
  end

  # Only allow internal absolute paths (a single leading "/"). Blocks absolute
  # URLs, protocol-relative ("//evil"), and backslash tricks ("/\\evil") so a
  # crafted ?return_to= can't open-redirect — including via a custom
  # turbo_stream redirect, which Rails' redirect host-guard does NOT cover
  # (the client `Turbo.visit`es the target and full-navigates cross-origin).
  def safe_return_to(value)
    value if value.present? && value.match?(%r{\A/(?![/\\])})
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
