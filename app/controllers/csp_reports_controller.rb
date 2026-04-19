# Receives CSP violation reports from browsers.
#
# The Content Security Policy initializer sets `report_uri "/csp-violation-report"`.
# Browsers POST a small JSON payload describing each blocked resource. We just log
# the report — operators can forward these logs to Sentry or another aggregator.
#
# Inherits from ActionController::Base (not ApplicationController) to avoid auth,
# CSRF, Pundit, and other before_actions. CSP reports must be accepted from any
# origin, with no authentication, and the browser discards non-2xx responses.
class CspReportsController < ActionController::Base
  MAX_BODY_BYTES = 8_192

  def create
    body = request.body.read(MAX_BODY_BYTES)
    report = parse_report(body)

    Rails.logger.warn("[CSP] violation: #{report.to_json}") if report.present?

    head :no_content
  end

  private
    def parse_report(body)
      return {} if body.blank?
      JSON.parse(body)
    rescue JSON::ParserError
      { raw: body.to_s.truncate(512) }
    end
end
