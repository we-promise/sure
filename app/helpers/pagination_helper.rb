module PaginationHelper
  # Below this many slots, Pagy only emits a short series because the
  # collection itself has that few pages — so every number is one or two
  # digits and the whole row fits a phone. Nothing is hidden there, otherwise a
  # 3-page pager would render as "1 3" with the middle page missing.
  SHORT_SERIES_LENGTH = 5

  # Extra classes for one item of `pagy.series` on the shared pagination bar.
  #
  # A full series (up to ~9 slots, and 3-digit page numbers on a large
  # collection) needs ~198px of row. A 360px phone leaves ~158px once the
  # chevrons and the per-page select are accounted for, so the row could not
  # fit — it used to wrap the last page onto a second line.
  #
  # On small screens we keep the first page, the last page, the current page
  # and the gaps, and drop the rest: "1 … 5 … 760" at ~156px. That is still a
  # usable pager — jump to either end, step with the chevrons — and the full
  # series comes back from `sm` up.
  #
  # `sm:` is a viewport breakpoint, so a narrow *column* on a wide screen (the
  # account activity feed with both sidebars open) still gets the full series.
  # The row is a nowrap flex that scrolls, so that case degrades to a short
  # horizontal scroll rather than wrapping again.
  def pagination_item_class(series, index)
    return nil if series.length <= SHORT_SERIES_LENGTH

    item = series[index]
    return nil if item == :gap                          # cheap, and marks the skip
    return nil if item.is_a?(String)                    # the current page
    return nil if index.zero?                           # first page
    return nil if index == series.length - 1            # last page

    "hidden sm:inline-flex"
  end
end
