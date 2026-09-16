# Compatibility entry point for the original Up-only preparation command.
class Provider::AccountData::Up::SourceSelection < Provider::AccountData::MigrationSourceSelection
  def self.ensure!(mapping:, family:)
    unless mapping.provider_migration_control.provider_key == "up"
      raise Conflict, "Up source selection requires its original account mapping"
    end
    super
  end
end
