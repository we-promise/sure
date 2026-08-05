class RoadmapPresenter
  def initialize(path: Rails.root.join("docs/roadmap.md"))
    @path = path
  end

  def phases
    @phases ||= RoadmapMarkdown.load(@path)
  end

  def status_counts
    phases.flat_map(&:items).group_by(&:status).transform_values(&:count)
  end
end
