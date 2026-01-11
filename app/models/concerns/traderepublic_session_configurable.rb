# frozen_string_literal: true

module TraderepublicSessionConfigurable
  extend ActiveSupport::Concern

  included do
    def ensure_session_configured!
      raise "Session not configured" unless traderepublic_item.session_configured?
    end
  end
end
