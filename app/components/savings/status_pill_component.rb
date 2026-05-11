class Savings::StatusPillComponent < ApplicationComponent
  VARIANTS = {
    on_track: { classes: "bg-green-500/10 text-success", icon: "circle-check" },
    behind: { classes: "bg-yellow-500/10 text-warning", icon: "triangle-alert" },
    reached: { classes: "bg-green-500/10 text-success", icon: "star" },
    no_target_date: { classes: "bg-surface-inset text-secondary", icon: "infinity" },
    paused: { classes: "bg-surface-inset text-secondary", icon: "pause" }
  }.freeze

  def initialize(goal:)
    @goal = goal
  end

  def status_key
    return :paused if @goal.paused?
    @goal.status
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
