# Plaid webhook event dispatch. Direct port of PlaidItem::WebhookProcessor;
# locates the Provider::Connection by plaid_item_id stored on metadata
# (instead of PlaidItem.plaid_id) and uses the framework's auth abstraction
# to flip status to requires_update.
class Provider::Plaid::WebhookHandler
  MissingConnectionError = Class.new(StandardError)

  def initialize(connection: nil, raw_body:, headers: {})
    @raw_body = raw_body
    @headers  = headers
    parsed = JSON.parse(raw_body)
    @webhook_type = parsed["webhook_type"]
    @webhook_code = parsed["webhook_code"]
    @item_id      = parsed["item_id"]
    @error        = parsed["error"]
    # Connection lookup may be supplied by the controller (when known) or
    # resolved here from metadata.plaid_item_id.
    @connection   = connection || Provider::Connection
                                  .where("metadata->>'plaid_item_id' = ?", @item_id)
                                  .first
  end

  def process
    unless @connection
      report_missing
      return
    end

    case [ webhook_type, webhook_code ]
    when [ "TRANSACTIONS", "SYNC_UPDATES_AVAILABLE" ],
         [ "INVESTMENTS_TRANSACTIONS", "DEFAULT_UPDATE" ],
         [ "HOLDINGS", "DEFAULT_UPDATE" ]
      @connection.sync_later
    when [ "ITEM", "ERROR" ]
      if error && error["error_code"] == "ITEM_LOGIN_REQUIRED"
        @connection.auth.mark_requires_update!(reason: "ITEM_LOGIN_REQUIRED")
      end
    else
      Rails.logger.warn("Unhandled Plaid webhook type: #{webhook_type}:#{webhook_code}")
    end
  rescue => e
    # Always return 200 to Plaid; capture failures via Sentry rather than 5xx.
    Sentry.capture_exception(e)
  end

  private

    attr_reader :webhook_type, :webhook_code, :item_id, :error

    def report_missing
      Sentry.capture_exception(
        MissingConnectionError.new("Received Plaid webhook for item with no matching Provider::Connection")
      ) do |scope|
        scope.set_tags(plaid_item_id: item_id)
      end
    end
end
