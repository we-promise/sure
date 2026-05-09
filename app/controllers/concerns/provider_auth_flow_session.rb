# Shared session-bridged flow state helpers for provider auth controllers.
#
# Auth flows that need to bridge cross-request state (OAuth2 redirect grants,
# Plaid Link OAuth-bank resumes, future protocols) stash the state in
# session[:provider_flows] keyed by a server-generated flow_id. The connection
# itself is created at flow completion when valid credentials exist.
#
# Each flow record is a Hash with at least { "created_at" => Time.current.to_i }.
# Records older than FLOW_TTL are pruned on write. The MAX_FLOWS cap drops the
# oldest entries first to prevent unbounded session growth.
module ProviderAuthFlowSession
  extend ActiveSupport::Concern

  FLOW_TTL  = 1.hour
  MAX_FLOWS = 20

  private

    def write_flow!(flow_id, state)
      session[:provider_flows] ||= {}
      pruned = session[:provider_flows].reject { |_, v| flow_expired?(v) }
      pruned = pruned.merge(flow_id => state)

      # Cap at MAX_FLOWS most-recent. Sort by created_at descending, keep the top N.
      if pruned.size > MAX_FLOWS
        pruned = pruned.sort_by { |_, v| -v["created_at"].to_i }.first(MAX_FLOWS).to_h
      end
      session[:provider_flows] = pruned
    end

    def peek_flow(flow_id)
      return nil if flow_id.blank?
      flow = session[:provider_flows]&.dig(flow_id)
      return nil unless flow.is_a?(Hash)
      return nil if flow_expired?(flow)
      flow
    end

    def consume_flow(flow_id)
      flow = peek_flow(flow_id)
      return nil unless flow
      session[:provider_flows] = (session[:provider_flows] || {}).except(flow_id)
      flow
    end

    def flow_expired?(flow)
      return true unless flow.is_a?(Hash)
      flow["created_at"].to_i < FLOW_TTL.seconds.ago.to_i
    end

    def write_active_link_flow!(provider_key, flow_id)
      session[:active_link_flows] ||= {}
      session[:active_link_flows][provider_key.to_s] = flow_id
    end

    def peek_active_link_flow(provider_key)
      session.dig(:active_link_flows, provider_key.to_s)
    end

    def consume_active_link_flow!(provider_key)
      flow_id = peek_active_link_flow(provider_key)
      session[:active_link_flows]&.delete(provider_key.to_s)
      flow_id
    end
end
