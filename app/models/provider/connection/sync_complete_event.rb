class Provider::Connection::SyncCompleteEvent
  def initialize(connection)
    @connection = connection
  end

  def broadcast
    # Placeholder: full-page refresh. Replace with surgical Turbo stream updates
    # (following EnableBankingItem::SyncCompleteEvent) when the TrueLayer UI is built out.
    Turbo::StreamsChannel.broadcast_refresh_to(
      @connection.family,
      requestId: SecureRandom.uuid
    )
  end
end
