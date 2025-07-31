class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def plaid
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    client = Provider::Registry.plaid_provider_for_region(:us)

    client.validate_webhook!(plaid_verification_header, webhook_body)

    PlaidItem::WebhookProcessor.new(webhook_body).process

    render json: { received: true }, status: :ok
  rescue => error
    Sentry.capture_exception(error)
    render json: { error: "Invalid webhook: #{error.message}" }, status: :bad_request
  end

  def plaid_eu
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    client = Provider::Registry.plaid_provider_for_region(:eu)

    client.validate_webhook!(plaid_verification_header, webhook_body)

    PlaidItem::WebhookProcessor.new(webhook_body).process

    render json: { received: true }, status: :ok
  rescue => error
    Sentry.capture_exception(error)
    render json: { error: "Invalid webhook: #{error.message}" }, status: :bad_request
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

  def choice
    webhook_body = request.body.read
    signature_header = request.headers["X-Choice-Signature"]

    begin
      # Parse the webhook body to extract the signature
      parsed_body = JSON.parse(webhook_body)
      received_signature = parsed_body["signature"]

      # Validate the signature
      validator = SignatureValidator.new(choice_webhook_secret)
      validator.validate_webhook!(parsed_body, received_signature)

      # Process the webhook
      ChoiceWebhookProcessor.new(webhook_body).process

      render json: { received: true }, status: :ok
    rescue JSON::ParserError => error
      Sentry.capture_exception(error)
      Rails.logger.error "JSON parser error: #{error.message}"
      render json: { error: "Invalid JSON" }, status: :bad_request
    rescue => error
      Sentry.capture_exception(error)
      Rails.logger.error "Choice webhook error: #{error.message}"
      render json: { error: "Webhook processing failed" }, status: :internal_server_error
    end
  end

  private
    def choice_webhook_secret
      ENV["CHOICE_WEBHOOK_SECRET"] || Rails.application.credentials.choice_webhook_secret
    end
end
