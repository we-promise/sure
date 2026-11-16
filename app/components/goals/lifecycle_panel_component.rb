# The panel between the goal header and its funding breakdown. Which panel a
# goal gets is a lifecycle question with five answers, and the template used to
# work it out inline from `completed?`, `maintained?`, `one_off?`, `status` and
# `may_complete?` — five predicates deep in ERB, where the ordering between
# them mattered and nothing said so.
#
# The decision lives here; the template only renders the answer.
class Goals::LifecyclePanelComponent < ApplicationComponent
  attr_reader :goal

  # `viewer_account_ids` are the goal's accounts THIS READER can reach, worked
  # out once in the controller and shared with the overflow menu. Defaulting to
  # none rather than to every account: a caller that forgets them withholds the
  # spend offer, which is the safe way to be wrong about a permission.
  def initialize(goal:, viewer_account_ids: [])
    @goal = goal
    @viewer_account_ids = viewer_account_ids
  end

  # Order is load-bearing, so it is stated once, here.
  #
  # `:reserve_shortfall` comes before `:empty`: a brand-new reserve sits at
  # zero balance and zero pace, and the generic "make your first transfer"
  # card would swallow it — where what it needs is the one figure a projection
  # cannot show, how far it is below its floor. Ordering it after also meant
  # asking a reserve for a pace it does not have.
  def panel
    return :inactive if goal.archived? || goal.paused?
    return :celebration if goal.completed? || goal.status == :reached || goal.status == :funded
    return :reserve_shortfall if goal.maintained?
    return :empty if goal.current_balance.to_d.zero? && goal.pace.to_d.zero?

    :projection
  end

  # --- inactive ---

  def inactive_icon = goal.archived? ? "archive" : "pause"

  def inactive_heading_key
    goal.archived? ? "inactive.heading_archived" : "inactive.heading_paused"
  end

  # --- celebration ---

  # Two situations reach this panel and they are not the same thing. A
  # `completed` goal is closed: its earmark has been released and its amount
  # frozen. A goal merely at 100% is still holding its money and still
  # competing with its siblings on the account.
  def closed? = goal.completed?

  def celebration_icon = goal.maintained? ? "shield-check" : "party-popper"

  def celebration_heading_key
    goal.maintained? ? "celebration.heading_reserve" : "celebration.heading"
  end

  def celebration_body_key
    return "celebration.body_reserve" if goal.maintained?

    closed? ? "celebration.body" : "celebration.body_reached"
  end

  def show_frozen_note? = closed? && goal.completed_at.present?

  # A reserve at its floor is in its normal state, not waiting to be closed:
  # offering to release the money would be offering to undo the thing it
  # exists for. Closing is also what releases the earmark, where archiving is
  # the gesture that does not — so a goal merely at 100% is offered `:close`,
  # not `:archive`.
  def celebration_action
    return :none if goal.maintained?
    return :close if !closed? && goal.one_off? && goal.may_complete?
    return :archive if goal.may_archive?

    :none
  end

  # Using the money is the step that normally comes *before* closing — the
  # close hint says so itself, "Do this once you have actually spent it" — and
  # until now the only way to say so was an entry in the overflow menu, at the
  # exact moment the page stops offering any other action. Adding money had a
  # button on this page; using it had none.
  #
  # Offered beside closing, never instead of it: plenty of goals are closed
  # without anything being recorded, and this must not read as a step to clear
  # first. Same condition as the menu entry, which stays where it is.
  def offer_recording_a_spend? = goal.spendable_within?(@viewer_account_ids)

  # --- projection ---


  # The chart draws its projection line with these same two variables
  # (`goal_projection_chart_controller.js`), so the legend swatch has to use
  # them too rather than the semantic border tokens — a legend whose colour
  # does not match its line is worse than the markup it would save.
  def projection_color
    goal.status == :on_track ? "var(--color-green-600)" : "var(--color-yellow-600)"
  end

  def show_catch_up? = goal.status == :behind && goal.monthly_target_amount.present?

  def show_projection_legend? = goal.target_date.present?

  def show_required_legend?
    goal.monthly_target_amount.to_d.positive? && goal.remaining_amount.to_d.positive?
  end
end
