require "uri"

module StoreLocation
  extend ActiveSupport::Concern

  included do
    helper_method :previous_path
    before_action :store_return_to
    after_action :clear_previous_path

    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found
  end

  def previous_path
    safe_return_path(session[:return_to]) || fallback_path
  end

private
  def stored_return_to_or(fallback_path, explicit_return_to: nil)
    if explicit_return_to.present?
      session.delete(:return_to)
      return safe_return_path(explicit_return_to) || fallback_path
    end

    safe_return_path(session.delete(:return_to)) || fallback_path
  end

  def handle_not_found
    if request.fullpath == session[:return_to]
      session.delete(:return_to)
      redirect_to fallback_path
    else
      head :not_found
    end
  end

  def store_return_to
    return if params[:return_to].blank?

    if (return_path = safe_return_path(params[:return_to]))
      session[:return_to] = return_path
    else
      session.delete(:return_to)
    end
  end

  def clear_previous_path
    if request.fullpath == session[:return_to]
      session.delete(:return_to)
    end
  end

  def fallback_path
    root_path
  end

  def safe_return_path(value)
    return nil if value.blank?

    path = value.to_s
    return nil unless path.start_with?("/")
    return nil if path.start_with?("//")

    uri = URI.parse(path)
    return nil if uri.scheme.present? || uri.host.present?

    path
  rescue URI::InvalidURIError
    nil
  end
end
