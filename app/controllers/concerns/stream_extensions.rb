module StreamExtensions
  extend ActiveSupport::Concern

  def stream_redirect_to(path, notice: nil, alert: nil)
    custom_stream_redirect(path, notice: notice, alert: alert)
  end

  def stream_redirect_back_or_to(path, notice: nil, alert: nil)
    custom_stream_redirect(path, redirect_back: true, notice: notice, alert: alert)
  end

  # A request made inside a turbo frame (such as the Add Account "modal" frame)
  # follows a plain redirect within the frame, so the page stays behind the
  # frame and its flash is never shown. Answer such requests with the frame
  # carrying a redirect stream action, which performs a full-page visit; other
  # requests get a normal redirect.
  def frame_redirect_to(path, notice: nil, alert: nil)
    return redirect_to(path, notice: notice, alert: alert) unless turbo_frame_request?

    flash[:notice] = notice if notice.present?
    flash[:alert] = alert if alert.present?

    render html: helpers.turbo_frame_tag(turbo_frame_request_id) {
      helpers.turbo_stream.action(:redirect, path)
    }
  end

  private
    def custom_stream_redirect(path, redirect_back: false, notice: nil, alert: nil)
      flash[:notice] = notice if notice.present?
      flash[:alert] = alert if alert.present?

      redirect_target_url = redirect_back ? request.referer : path
      render turbo_stream: turbo_stream.action(:redirect, redirect_target_url)
    end
end
