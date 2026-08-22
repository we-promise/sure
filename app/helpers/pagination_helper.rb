module PaginationHelper
  # Below this many slots, Pagy only emits a short series because the
  # collection itself has that few pages — so every number is one or two
  # digits and the whole row fits a phone. Nothing is hidden there, otherwise a
  # 3-page pager would render as "1 3" with the middle page missing.
  SHORT_SERIES_LENGTH = 5

  # Per-slot rendering plan for `pagy.series` on the shared pagination bar, one
  # entry per slot:
  #
  #   :visible       shown at every width
  #   :desktop_only  hidden below `sm`
  #   :collapsed     hidden below `sm`, and a mobile-only "…" stands in for the
  #                  run of hidden slots starting here
  #
  # A full series (up to ~9 slots, and 3-digit page numbers on a large
  # collection) needs ~198px of row. A 360px phone leaves ~158px once the
  # chevrons and the per-page select are accounted for, so the row could not
  # fit — it used to wrap the last page onto a second line.
  #
  # On small screens we keep the first page, the last page, the current page
  # and Pagy's own gaps, and drop the rest. Dropping alone is not enough: it
  # would render "1 3 … 760" for [1, 2, "3", 4, 5, :gap, 760], or "1 6" for a
  # gapless 6-page series, implying those pages are adjacent when a page was
  # silently removed. So each dropped run is represented by a "…" of its own —
  # unless Pagy already put a gap right beside that run, which would otherwise
  # read as "… …".
  #
  # `sm:` is a viewport breakpoint, so a narrow *column* on a wide screen (the
  # account activity feed with both sidebars open) still gets the full series.
  # The row is a nowrap flex that scrolls, so that case degrades to a short
  # horizontal scroll rather than wrapping again.
  def pagination_mobile_plan(series)
    return Array.new(series.length, :visible) if series.length <= SHORT_SERIES_LENGTH

    plan = series.each_with_index.map do |item, index|
      keep = item == :gap ||                    # Pagy's own elision
             item.is_a?(String) ||              # the current page
             index.zero? ||                     # first page
             index == series.length - 1         # last page
      keep ? :visible : :desktop_only
    end

    # Promote the head of each dropped run to `:collapsed` so the view can put
    # a "…" there, unless a real gap already borders the run. Runs are read off
    # `dropped` rather than `plan`, which is being mutated as we go — reading
    # the live array made every slot after the head look like a fresh run and
    # emitted one "…" per hidden page.
    dropped = plan.map { |state| state == :desktop_only }

    plan.each_index do |index|
      next unless dropped[index]
      next if index.positive? && dropped[index - 1] # not the head of its run

      run_end = index
      run_end += 1 while dropped[run_end + 1]

      before = index.positive? ? series[index - 1] : nil
      after = series[run_end + 1]

      plan[index] = :collapsed unless before == :gap || after == :gap
    end

    plan
  end
end
