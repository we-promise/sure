# One job's share of an Ai::GenerationRun: the ids its last batch left unanswered (`pending`), then
# the run's ids from the cursor, read in chunks and filtered by the requester until `size` of them
# match. The first chunk is one batch's worth; each one after a short chunk doubles, up to CHUNK. Ids it reads count as examined, matching or not (already categorized, locked, gone), so
# the requester counts them handled; ids after the last one it took stay in the table for the next
# job. A stretch where nothing matches is passed over inside one job, and each id is read about
# once in the whole run.
class Ai::GenerationRun::Window
  CHUNK = 500

  attr_reader :run, :cursor, :matched_ids, :examined_ids

  def initialize(run, cursor:, pending:, size:)
    @run = run
    @cursor = @start = cursor.to_i
    @pending = Array(pending)
    @size = size
    @matched_ids = []
    @examined_ids = []
  end

  # The first window of the run: nothing read yet and nothing left over.
  def first? = @start.zero? && @pending.empty?

  # Yields chunks of ids, expecting the ones that match back. Returns the matching ids, at most
  # `size` from the table; pending ids are always examined, since there are never more than a batch.
  def take_matching
    return @matched_ids if @taken

    @taken = true
    if @pending.any?
      # Examined before the query, so a query that raises still leaves them this job's to release.
      @examined_ids.concat(@pending)
      matching = yield(@pending).to_set
      @matched_ids.concat(@pending.select { matching.include?(_1) })
    end

    chunk = [ @size, CHUNK ].min
    until full? || exhausted?
      rows = run.ids_from(@cursor, chunk)
      chunk = [ chunk * 2, CHUNK ].min
      break @cursor = run.item_count if rows.empty?   # rows gone from under the run: nothing left to read

      matching = yield(rows.map(&:last)).to_set
      rows.each do |position, id|
        @examined_ids << id
        @cursor = position + 1
        @matched_ids << id if matching.include?(id)
        break if full?
      end
    end
    @matched_ids
  end

  def taken? = @taken.present?

  # Every id in the table has been read. Pending ids aren't counted: the job checks the result for those.
  def exhausted? = @cursor >= run.item_count

  # Ids no job has examined yet, the ones a run that gives up here must release.
  def outstanding = (taken? ? 0 : @pending.size) + [ run.item_count - @cursor, 0 ].max

  private
    def full? = @matched_ids.size >= @size
end
