class ChoiceWebhookProcessor
  def initialize(webhook_body)
    @webhook_body = webhook_body
    @parsed_body = JSON.parse(webhook_body)
  end

  def process
    case webhook_type
    when "test-hook-1"
      handle_test_hook
    when "test-hook-2"
      handle_test_hook_2
    else
      Rails.logger.warn("Unhandled ChoiceBank webhook type: #{webhook_type}")
    end
  rescue => e
    # Always ensure we return a 200 to keep endpoint healthy
    Sentry.capture_exception(e) do |scope|
      scope.set_tags(webhook_type: webhook_type, webhook_id: webhook_id)
    end
  end

  private
    attr_reader :webhook_body, :parsed_body

    def webhook_type
      @webhook_type ||= parsed_body["type"]
    end

    def webhook_id
      @webhook_id ||= parsed_body["id"]
    end

    def webhook_data
      @webhook_data ||= parsed_body["data"] || {}
    end

    def handle_test_hook
      Rails.logger.info("Processing test-hook-1 webhook: #{webhook_id}")
      Rails.logger.info("Webhook data: #{webhook_data}")
    end

    def handle_test_hook_2
      Rails.logger.info("Processing test-hook-2 webhook: #{webhook_id}")
      Rails.logger.info("Webhook data: #{webhook_data}")
    end
end 