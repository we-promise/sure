class Savings::StatusPillComponent < ApplicationComponent
  # Text colors here intentionally use palette steps (green-700 / yellow-700 /
  # gray-700) rather than `text-success` / `text-warning` / `text-secondary`
  # tokens because the functional tokens drop below WCAG 1.4.3 4.5:1 on tinted
  # surfaces in light mode (~2.88:1 / 3.0:1 / 4.16:1). Local override only;
  # revert once we-promise/sure#1736 lands token-level fixes.
  VARIANTS = {
    on_track: { classes: "bg-green-500/10 text-green-700", icon: "circle-check" },
    behind: { classes: "bg-yellow-500/10 text-yellow-700", icon: "triangle-alert" },
    reached: { classes: "bg-green-500/10 text-green-700", icon: "star" },
    no_target_date: { classes: "bg-surface-inset text-gray-700", icon: "infinity" },
    paused: { classes: "bg-surface-inset text-gray-700", icon: "pause" },
    archived: { classes: "bg-surface-inset text-gray-700", icon: "archive" }
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
    I18n.t("savings_goals.status.#{status_key}")
  end

  def classes
    variant[:classes]
  end

  def icon_name
    variant[:icon]
  end
end
