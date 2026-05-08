class Settings::HealthSummary < ApplicationComponent
  def initialize(counts:)
    @counts = counts
  end

  private
    attr_reader :counts

    def connected_count      = counts[:connected]
    def needs_attention_count = counts[:needs_attention]
    def errors_count         = counts[:errors]
    def accounts_synced_count = counts[:accounts_synced]

    def tiles
      [
        {
          count: connected_count,
          label: t("settings.providers.health.connected"),
          color_class: connected_count > 0 ? "text-success" : "text-subdued"
        },
        {
          count: needs_attention_count,
          label: t("settings.providers.health.needs_attention"),
          color_class: needs_attention_count > 0 ? "text-warning" : "text-subdued"
        },
        {
          count: errors_count,
          label: t("settings.providers.health.errors"),
          color_class: errors_count > 0 ? "text-destructive" : "text-subdued"
        },
        {
          count: accounts_synced_count,
          label: t("settings.providers.health.accounts_synced"),
          color_class: "text-primary"
        }
      ]
    end
end
