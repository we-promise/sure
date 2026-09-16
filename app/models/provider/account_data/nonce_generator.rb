# Nonces commit before the signed HTTP request. They are connection state, not a
# financial cursor; rolling back a batch must never roll back a consumed nonce.
class Provider::AccountData::NonceGenerator
  def initialize(connection:, clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) })
    @connection_id, @family_id, @clock = connection.id, connection.family_id, clock
  end

  def call
    unless ProviderConnection.connection.open_transactions.zero?
      raise ArgumentError, "Request nonce must commit outside an enclosing transaction"
    end
    connection = ProviderConnection.where(family_id: @family_id).find(@connection_id)
    connection.with_lock do
      control = connection.provider_migration_control
      unless connection.good? && !connection.scheduled_for_deletion? && (control.nil? || control.native_owned?)
        raise Provider::AccountData::StaleWriter, "Connection does not own signed requests"
      end
      checkpoint = connection.provider_sync_checkpoints.find_or_initialize_by(stream: "request_nonce", scope_key: "connection")
      previous = checkpoint.persisted? ? integer(checkpoint.state.fetch("last_nonce")) : legacy_seed(connection, control)
      candidate = integer(@clock.call)
      nonce = [ candidate, previous + 1 ].max.to_s
      checkpoint.state = { "last_nonce" => nonce }
      checkpoint.save!
      nonce
    end
  end

  private
    def legacy_seed(connection, control)
      return 0 unless control
      unless connection.provider_key == "kraken" && control.legacy_type == "KrakenItem"
        raise Provider::AccountData::UnsupportedCapability, "No migrated nonce contract for this source"
      end
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "legacy_state", scope_key: "KrakenItem:#{control.legacy_id}")
      unless checkpoint.state["format"] == Provider::AccountData::MigrationCopier::SNAPSHOT_FORMAT
        raise Provider::AccountData::InvalidResponse, "Unsupported migrated request state"
      end
      columns = Provider::AccountData::MigrationValue.decode(checkpoint.state.fetch("columns"))
      integer(columns.fetch("last_nonce") || 0)
    end

    def integer(value)
      unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d+\z/))
        raise Provider::AccountData::InvalidResponse, "Invalid request nonce state"
      end
      number = Integer(value)
      raise Provider::AccountData::InvalidResponse, "Invalid request nonce state" if number.negative?
      number
    end
end
