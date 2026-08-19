class Goals::StatusPillComponent < ApplicationComponent
  # Maps the goal's display_status to the DS::Pill primitive's tone +
  # glyph. Outline style is used so the pill keeps its colored border on
  # any card background (resting bg-container, hover bg-surface-hover);
  # the filled / soft variants blended into the hover state and lost
  # contrast on cards.
  VARIANTS = {
    on_track:       { tone: :green, icon: "circle-check" },
    behind:         { tone: :amber, icon: "triangle-alert" },
    reached:        { tone: :green, icon: "star" },
    completed:      { tone: :green, icon: "circle-check-big" },
    no_target_date: { tone: :gray,  icon: "infinity" },
    paused:         { tone: :gray,  icon: "pause" },
    archived:       { tone: :gray,  icon: "archive" }
  }.freeze

  def initialize(goal:)
    @goal = goal
  end

  def status_key
    @goal.display_status
  end

  def variant
    VARIANTS.fetch(status_key, VARIANTS[:no_target_date])
  end

  def label
    I18n.t("goals.status.#{status_key}", default: status_key.to_s.titleize)
  end
end
