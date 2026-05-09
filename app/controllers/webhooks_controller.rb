class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def stripe
    stripe_provider = Provider::Registry.get_provider(:stripe)

    begin
      webhook_body = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

      stripe_provider.process_webhook_later(webhook_body, sig_header)

      head :ok
    rescue JSON::ParserError => error
      Sentry.capture_exception(error)
      Rails.logger.error "JSON parser error: #{error.message}"
      head :bad_request
    rescue Stripe::SignatureVerificationError => error
      Sentry.capture_exception(error)
      Rails.logger.error "Stripe signature verification error: #{error.message}"
      head :bad_request
    end
  end
end
