class EmailAlertMessage::Processor
  SOURCE = "email_alert".freeze

  attr_reader :message

  def initialize(message)
    @message = message
  end

  def process
    return message if message.processed? || message.ignored? || message.rejected?

    alert = message.parsed_alert || parse_and_store
    return message unless alert

    provider_account = find_or_create_provider_account(alert)
    message.update!(email_alert_account: provider_account)
    update_known_balance(provider_account, alert)

    account = provider_account.current_account
    return finish(:awaiting_link) unless account

    import_transaction(account, alert)
    finish(:processed)
  rescue => e
    capture_failure(e)
    finish(:failed, e.message)
  end

  private

    def item
      message.email_alert_item
    end

    def parse_and_store
      mime = message.mime
      parser_class = EmailAlert::Parsers.for_domain(mime.from_domain)
      unless parser_class
        finish(:rejected, "Unsupported sender #{mime.from_address}")
        return nil
      end

      unless mime.dkim.passes_for?(mime.from_domain)
        results = mime.dkim.results
        if results.any? { |r| r.status == :temperror }
          finish(:failed, "DKIM key lookup failed; will retry")
        else
          reasons = results.map { |r| "#{r.domain}: #{r.reason}" }.presence&.join("; ") || "no DKIM signature"
          finish(:rejected, "DKIM verification failed (#{reasons})")
        end
        return nil
      end

      alert = parser_class.new(mime).parse
      unless alert
        finish(:ignored, "Not a transaction alert")
        return nil
      end

      message.update!(parsed_payload: alert.to_h_for_storage.to_json)
      alert
    end

    def find_or_create_provider_account(alert)
      key = "#{alert.parser_key}:#{alert.account_identifier}"
      item.email_alert_accounts.create_with(
        name: alert.account_name,
        currency: alert.currency,
        provider: alert.parser_key,
        institution_metadata: { name: alert.institution_name }
      ).find_or_create_by!(email_alert_account_id: key)
    rescue ActiveRecord::RecordNotUnique
      item.email_alert_accounts.find_by!(email_alert_account_id: key)
    end

    # Alerts can arrive out of order; only a balance at least as recent as the
    # last one seen replaces it. EmailAlertAccount::Processor anchors it.
    def update_known_balance(provider_account, alert)
      return if alert.balance.nil? || alert.occurred_at.nil?
      return if provider_account.balance_as_of.present? && provider_account.balance_as_of > alert.occurred_at

      provider_account.update!(current_balance: alert.balance, balance_as_of: alert.occurred_at)
    end

    def import_transaction(account, alert)
      Account::ProviderImportAdapter.new(account).import_transaction(
        external_id: alert.external_id,
        amount: alert.entry_amount,
        currency: alert.currency,
        date: entry_date(alert),
        name: alert.description,
        source: SOURCE,
        category_id: category_for(alert)&.id,
        extra: { SOURCE => alert.details.merge(
          institution: alert.parser_key,
          reference: alert.reference,
          occurred_at: alert.occurred_at&.iso8601
        ).compact.deep_stringify_keys },
        replace_extra_namespaces: [ SOURCE ]
      )
    end

    def entry_date(alert)
      time = alert.occurred_at || message.mime.sent_at || message.received_at
      timezone = item.family.timezone.presence || "UTC"
      time.in_time_zone(timezone).to_date
    end

    def category_for(alert)
      return nil unless alert.category_hint == :bank_fees

      item.family.categories.fees.first ||
        item.family.categories.find_or_create_by!(name: I18n.t(Category::FEES_NAME_KEY))
    end

    def finish(status, error = nil)
      message.update!(status: status, processing_error: error, processed_at: Time.current)
      message
    end

    def capture_failure(error)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Email alert processing failed: #{error.class}: #{error.message}",
        source: self.class.name,
        provider_key: "email_alert",
        family: item.family,
        account_provider: message.email_alert_account&.account_provider,
        metadata: { email_alert_message_id: message.id, subject: message.subject }
      )
    end
end
