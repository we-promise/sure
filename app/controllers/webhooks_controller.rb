class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def plaid
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    client = plaid_webhook_provider(:us, webhook_body)

    client.validate_webhook!(plaid_verification_header, webhook_body)

    PlaidItem::WebhookProcessor.new(webhook_body).process

    render json: { received: true }, status: :ok
  rescue => error
    Sentry.capture_exception(error)
    Rails.logger.error("Webhook error: #{error.class} - #{error.message}")
    render json: { error: "Invalid webhook" }, status: :bad_request
  end

  def plaid_eu
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    client = plaid_webhook_provider(:eu, webhook_body)

    client.validate_webhook!(plaid_verification_header, webhook_body)

    PlaidItem::WebhookProcessor.new(webhook_body).process

    render json: { received: true }, status: :ok
  rescue => error
    Sentry.capture_exception(error)
    Rails.logger.error("Webhook error: #{error.class} - #{error.message}")
    render json: { error: "Invalid webhook" }, status: :bad_request
  end

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

  private
    def plaid_webhook_provider(region, webhook_body)
      item_id = JSON.parse(webhook_body).fetch("item_id")
      plaid_item = PlaidItem.find_by(plaid_id: item_id, plaid_region: region.to_s)

      plaid_item&.plaid_provider || Provider::Registry.plaid_provider_for_region(region)
    rescue JSON::ParserError, KeyError
      Provider::Registry.plaid_provider_for_region(region)
    end
end
