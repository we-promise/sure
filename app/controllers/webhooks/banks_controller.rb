class Webhooks::BanksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def receive
    provider_key = params[:provider]&.to_sym
    meta = Provider::Banks::Registry.find(provider_key)
    return head :not_found unless meta

    raw_body = request.raw_post
    headers = request.headers

    # Find matching connection by verifying signature with its credentials
    connections = BankConnection.where(provider: provider_key.to_s)
    matched = nil

    if connections.any? && meta.provider_class.instance_methods.include?(:verify_webhook_signature!)
      connections.find do |conn|
        provider = meta.provider_class.new(parse_credentials(conn.credentials))
        begin
          if provider.verify_webhook_signature!(raw_body, headers)
            matched = conn
            true
          else
            false
          end
        rescue => e
          Rails.logger.warn("Webhook signature verification error for #{provider_key} connection #{conn.id}: #{e.message}")
          false
        end
      end
    end

    return head :unauthorized if connections.any? && matched.nil?

    # Schedule a sync for the matched connection(s)
    (matched ? [matched] : connections).each { |c| c.sync_later }

    head :ok
  end

  private
    def parse_credentials(creds)
      case creds
      when String
        JSON.parse(creds) rescue {}
      when Hash
        creds
      else
        {}
      end
    end
end
