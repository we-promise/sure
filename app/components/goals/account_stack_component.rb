class Goals::AccountStackComponent < ApplicationComponent
  def initialize(accounts:, max: 3, color_map: nil)
    @accounts = accounts
    @max = max
    @color_map = color_map || {}
  end

  def shown
    @accounts.first(@max)
  end

  def extra_count
    (@accounts.size - @max).clamp(0..)
  end

  def initial_for(account)
    account.name.to_s.strip.first&.upcase || "?"
  end

  # Color for this account, sourced from the per-goal color map when the
  # caller provided one (so the stack on the index card matches the funding
  # widget on the show page). Falls back to the name-hashed palette pick
  # for backward compatibility with any caller that didn't pass `color_map:`.
  def color_for(account)
    @color_map[account.id] || Goals::AvatarComponent.color_for(account.name)
  end
end
