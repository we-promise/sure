# Generic webhook receiver for Provider::Connection adapters.
#
# Routes:
#   POST /webhooks/providers/:provider_key
#
# Responsibilities are deliberately minimal — verify the signature via the
# adapter, instantiate the adapter's webhook_handler_class, dispatch. All
# provider-specific logic (signature scheme, payload parsing, event handling)
# lives on the adapter, not in this controller.
#
# Response codes:
#   200 — signature verified; handler ran (any handler-side errors are
#         captured to Sentry but the endpoint still returns 200 so upstream
#         providers don't 24-hour-retry on transient/in-progress bugs)
#   400 — signature verification failed, or the provider doesn't accept webhooks
#   404 — unknown provider_key (registry lookup failed)
class Webhooks::ProviderController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def receive
    adapter = begin
      Provider::ConnectionRegistry.adapter_for(params[:provider_key])
    rescue NotImplementedError
      head :not_found and return
    end

    raw_body = request.body.read

    # Signature verification is the gate. If this raises, the request is
    # rejected — providers should not retry an invalid signature.
    begin
      adapter.verify_webhook!(headers: request.headers, raw_body: raw_body)
    rescue NotImplementedError => e
      Sentry.capture_exception(e)
      render json: { error: "Provider does not accept webhooks" }, status: :bad_request
      return
    rescue => e
      Sentry.capture_exception(e)
      Rails.logger.warn("[Webhooks::ProviderController] #{params[:provider_key]} signature verification failed: #{e.class}: #{e.message}")
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    # Handler runs post-signature. Any error here is a bug in our code, NOT a
    # bad webhook — return 200 so the provider doesn't retry, but capture to
    # Sentry so the bug surfaces.
    begin
      adapter.webhook_handler_class.new(raw_body: raw_body, headers: request.headers).process
    rescue => e
      Sentry.capture_exception(e)
      Rails.logger.error("[Webhooks::ProviderController] #{params[:provider_key]} handler failed: #{e.class}: #{e.message}")
    end

    render json: { received: true }, status: :ok
  end
end
