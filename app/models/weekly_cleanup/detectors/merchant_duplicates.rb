# The merchant de-dup report (deterministic — WeeklyCleanup::MerchantDedup does
# normalization + trigram similarity; no LLM). Surfaces likely duplicate
# merchant clusters so an admin can merge them by hand.
class WeeklyCleanup::Detectors::MerchantDuplicates < WeeklyCleanup::Detector
  MAX_CLUSTERS_LISTED = 5

  def generate
    result = WeeklyCleanup::MerchantDedup.call(family.merchants.alphabetically)
    return nil if result.clusters.empty?

    samples = result.clusters.first(MAX_CLUSTERS_LISTED).map do |cluster|
      names = cluster.members.map(&:name)
      "#{names.first} ⇄ #{names.second}" + (cluster.members.size > 2 ? " (+#{cluster.members.size - 2} more)" : "")
    end

    Finding.new(
      key: self.class.key,
      heading: I18n.t("weekly_cleanup.detectors.merchant_duplicates.heading",
        total: result.total, clusters: result.clusters.size, coverage: result.coverage_pct),
      count: result.clusters.size,
      samples: samples
    )
  end
end
