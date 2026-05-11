class Savings::StatusPillComponent < ApplicationComponent
  VARIANTS = {
    on_track: { classes: "bg-green-500/10 text-success", dot: "bg-green-600" },
    behind: { classes: "bg-yellow-500/10 text-warning", dot: "bg-yellow-500" },
    reached: { classes: "bg-green-500/10 text-success", dot: "bg-green-600" },
    no_target_date: { classes: "bg-surface-inset text-secondary", dot: "bg-gray-400" }
  }.freeze

  def initialize(goal:)
    @goal = goal
  end

  def status
    @goal.status
  end

  def variant
    VARIANTS.fetch(status, VARIANTS[:no_target_date])
  end

  def label
    I18n.t("savings_goals.status.#{status}")
  end

  def classes
    variant[:classes]
  end

  def dot_classes
    variant[:dot]
  end
end
