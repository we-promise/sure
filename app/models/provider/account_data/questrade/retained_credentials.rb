# A copied refresh token is usable only if its original legacy session finished.
# The retained API server is historical context, never an authenticated endpoint.
class Provider::AccountData::Questrade::RetainedCredentials
  FORMAT = "questrade-retained-credentials/v1".freeze
  Fence = Provider::AccountData::LegacyWriterFence

  def self.assert_copyable!(item)
    return true unless item.is_a?(QuestradeItem)

    Fence.assert_exclusive!(item)
    current = QuestradeItem.find_by(id: item.id, family_id: item.family_id)
    unless current && !current.scheduled_for_deletion? && current.good? &&
        current.refresh_token.is_a?(String) && current.refresh_token.present?
      raise Provider::AccountData::MigrationCopier::Conflict, "Questrade requires legacy credential recovery before migration"
    end
    true
  end

  def self.live_input(connection:)
    reader(connection).item_descriptor
  end

  def self.build(connection:, observed_at:, external_accounts: nil)
    retained = reader(connection).item
    return nil unless retained

    attributes = retained.attributes
    unless attributes["status"] == "good" && attributes["scheduled_for_deletion"] == false &&
        attributes["refresh_token"].is_a?(String) && attributes["refresh_token"].present?
      # A later native token or revision is not proof that the possibly consumed
      # original token was safely replaced. Reauthorize in legacy and recopy.
      raise Provider::AccountData::StaleWriter, "Questrade retained credentials require recovery"
    end
    Provider::AccountData::MigrationManifest.copy_value(
      "format" => FORMAT, "provenance" => retained.context,
      "status" => attributes.fetch("status"), "historical_api_server" => attributes["api_server"])
  end

  def self.reader(connection)
    Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "questrade")
  end
  private_class_method :reader
end
