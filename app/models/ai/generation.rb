# The base class of every structured-output feature. A feature is declared, not
# implemented: its key, its prompt folder, its schema and, when it takes a list, how the list is
# batched and merged. `call` is the only place that does the rest, in this order:
#
#   1. Ai::Router#resolve(feature); unavailable returns Ai::Result.unavailable(reason).
#   2. Stop if `cancelled` returns true, here and before every batch.
#   3. Take the first route not marked down (Ai::DownMarks). Render its prompt (Ai::Prompt), take
#      the next batch sized for its model (Ai::Batch), call its transport's `generate`, and
#      coerce the answer (Ai::Schema). On a `judge` model, the feature's judgement (`judged_by`)
#      answers the same batch instead.
#   4. On a failover error (Ai::DownMarks::FAILOVER), mark it down and take the next route. On
#      InvalidOutput, escalate to the next route; when no route answers it, halve the batch on
#      the route that found it unusable (BISECT_DEPTH times at most) and skip what still fails. On ContextTooLong
#      or an answer cut at the output limit, halve the batch on the same route; a single item
#      that still can't fit escalates. A route with a smaller batch_size takes the batch in
#      pieces. A batch no route can use is skipped, unless its answers were unusable before any
#      batch in the run worked (`answered_before` carries that across Ai::GenerationJob's
#      chain). Skipped items are logged. Nothing else is retried here; the transport has retried
#      429s and 5xxs.
#   5. Return an Ai::Result with the route that answered and the items not reached. Answers keep
#      their input order even when a fallback recovers an earlier piece. An outage on a later batch
#      ends the run with the earlier answers and the rest left for a later job; a slice no route can
#      use is skipped and logged. When the feature declares `shadow` and the family's rate samples
#      this call, enqueue Ai::ShadowJob with the ids of every item sent, answered or not, apart from
#      those left for a later job (Ai::GenerationJob does this itself, after applying the answer).
#
# `call(batches: 1)` runs one batch, which is what Ai::GenerationJob does (small batches,
# so other work takes turns); plain `call` runs them all and merges the answers in input order.
# `call!` returns the value or raises the Ai::Error, for jobs.
class Ai::Generation
  # How many times a batch whose answer is unusable on every route is halved to find the
  # transactions that break it.
  BISECT_DEPTH = 2

  # A failover or an unusable answer part-way through a split slice: the pieces answered, and
  # every item not answered yet, for the next route, bisection or a later job.
  class Interrupted < StandardError
    attr_reader :values, :pending, :error

    def initialize(values, pending, error)
      @values, @pending, @error = values, pending, error
      super(error.message)
    end
  end

  class_attribute :feature_key, :prompt_key, :static_schema, :schema_label, :batch_key, :merge_key, :merge_by,
                  :blank_item_check, :judgement_class, :shadow_compare, :shadow_subject, instance_writer: false
  class_attribute :key_aliases, default: {}, instance_writer: false
  class_attribute :required_keys, default: [], instance_writer: false

  class << self
    def feature(key) = self.feature_key = key.to_sym

    # The default prompt folder in app/prompts; a route entry can name another.
    def prompt(name) = self.prompt_key = name.to_s

    # A constant schema; features whose enum depends on the input define #schema instead.
    def schema(hash) = self.static_schema = hash

    # The schema's name in a strict response_format.
    def schema_name(name) = self.schema_label = name.to_s

    # The initializer keyword that holds the items, which are batched.
    def batch(key) = self.batch_key = key.to_sym

    # How batch answers combine: the list key in the schema, and the id each item carries.
    def merge(key, by:)
      self.merge_key = key.to_sym
      self.merge_by = by.to_sym
    end

    # An item the model left blank, for `auto` JSON mode's fallback.
    def blank_item(&check) = self.blank_item_check = check

    # Field names models use instead of the schema's.
    def aliases(map) = self.key_aliases = map

    # Item fields without which an answer can't be matched to its input.
    def required(*keys) = self.required_keys = keys.map(&:to_sym)

    # The Ai::Judgement that answers this feature on a `judge` model (Jev). It takes #arguments
    # and returns the same value shape.
    def judged_by(klass) = self.judgement_class = klass

    # Runs the feature on its `shadow_<feature>` route as its own job, compared and never applied.
    # `compare` maps a value to { item id => [value, confidence] }, run on the
    # generation, so it can turn names into ids; `subject` is the class each item id names.
    def shadow(compare:, subject:)
      self.shadow_compare = compare
      self.shadow_subject = subject.to_s
    end
  end

  attr_reader :family, :user

  def initialize(family:, user: nil)
    @family, @user = family, user
  end

  def schema = static_schema

  # Locals for the prompt templates; a batched feature includes its items.
  def prompt_locals = {}

  # Fields the feature matches itself instead of by the schema's enum (Ai::Schema's `match:`).
  def matchers = {}

  def items = batch_key ? Array(instance_variable_get(:"@#{batch_key}")) : nil

  # What one item costs a request, in tokens, for Ai::Batch: its text by default. A page image
  # costs a fixed estimate (PDF import).
  def item_cost(item) = Assistant::TokenEstimator.estimate(item)

  # Files sent with this request's input (Ai::Attachment): a PDF or page images.
  def attachments = []

  # Capabilities this call needs beyond the feature's own, such as `vision` for page images: a
  # route whose model lacks them is skipped, not sent a request it would refuse.
  def needs = []

  # How the answers of each batch combine: the merge list's items, one per id. A feature whose
  # items have no id (statement rows) merges its own way.
  def merge_values(values)
    { merge_key => values.flat_map { Array(_1[merge_key]) }.index_by { _1[merge_by] }.values }
  end

  # The initializer's arguments other than the family, for the judgement on a `judge` route.
  def arguments = raise(NotImplementedError, "#{self.class.name} defines no arguments")

  # A copy holding only `slice`, so prompt_locals only ever sees one batch.
  def with_items(slice) = dup.tap { _1.instance_variable_set(:"@#{batch_key}", slice) }

  def call!(...) = call(...).value!

  # The value as { item id => [value, confidence] }, for Ai::Comparison.
  def compared(value) = instance_exec(value, &shadow_compare)

  # answered_before: an earlier call in the same run answered a batch (Ai::GenerationJob's chain).
  # shadow: false when the caller samples the shadow itself, once its answer is applied.
  # down_marks: false for a diagnostic, which must neither skip a route production marked down nor
  # mark one down for production.
  def call(batches: nil, cancelled: nil, plan: nil, answered_before: false, shadow: true, down_marks: true)
    @down_marks = down_marks ? Ai::DownMarks : Ai::DownMarks::Ignored
    plan ||= Ai::Router.new(family:, user:).resolve(feature_key)
    return Ai::Result.unavailable(plan) unless plan.is_a?(Ai::Plan)

    @recorded_feature = plan.feature

    routes = plan.routes.select { servable?(_1) }
    return Ai::Result.unavailable(Ai::Availability.unavailable(feature_key, :capability_missing)) if routes.empty?

    @logged_ids = Set.new
    @skipped = []
    @skipped_in_slice = Set.new
    result = batch_key ? call_batched(routes, batches:, cancelled:, answered_before:) : call_single(routes, cancelled:)
    Ai::Shadow.enqueue(self, result) if shadow && !shadow_run?
    result
  rescue Ai::Error::Base => error
    Ai::Result.failure(error)
  end

  # The share of this batch's items the model left blank or missed.
  def failed_ratio(json)
    return 0.0 unless blank_item_check && items.any?

    answered = Array(coerce(json)[merge_key]).index_by { _1[merge_by] }.values   # one per item, as the merge keeps
    blank = answered.count { blank_item_check.call(_1) }
    (blank + [ items.size - answered.size, 0 ].max) / items.size.to_f
  rescue Ai::Error::InvalidOutput
    1.0
  end

  def coerce(json)
    Ai::Schema.coerce(json, schema, aliases: key_aliases, match: matchers, required: required_keys).tap do |value|
      # A batch answered with nothing would otherwise count as answered, and its items be dropped
      # without being logged as unanswered.
      raise Ai::Error::InvalidOutput, "no answers for #{items.size} items" if merge_key && items.present? && value[merge_key].empty?
    end
  end

  private
    def servable?(route)
      return judgement_class.present? && route.model.capable?(:judge) if route.judge?

      route.model.capable?(:structured_output, *needs)
    end

    def call_single(routes, cancelled:)
      raise Ai::Error::Cancelled, "cancelled" if cancelled&.call

      route, value = on_routes(routes, nil).first.first
      result(value:, route:)
    end

    def call_batched(routes, batches:, cancelled:, answered_before:)
      remaining = items.dup
      values = []
      served = nil
      answered_by = {}
      done = 0

      while remaining.any? && (batches.nil? || done < batches)
        raise Ai::Error::Cancelled, "cancelled" if cancelled&.call

        route = routes.find { !@down_marks.down?(_1) } || routes.first
        slice = Ai::Batch.first_slice(remaining, model: route.model, fixed_tokens: fixed_tokens(route), cost: method(:item_cost))
        @skipped_in_slice.clear   # a unit skipped by two paths in one slice is still one skipped unit
        answers, unanswered = begin
          on_routes(routes, slice)
        rescue Ai::Error::ContextTooLong, Ai::Error::InvalidOutput, Ai::Error::UnsupportedInput => error
          # A slice no route can use is skipped, so it doesn't end the run for the items after it.
          # Unusable answers before anything in the run worked still fail: the model may be the problem.
          raise if [ Ai::Error::InvalidOutput, Ai::Error::UnsupportedInput ].any? { error.is_a?(_1) } &&
                   values.empty? && !answered_before

          log_unanswered(slice)
          [ [], [] ]
        rescue Pdf::PageImages::Error
          # A later page that can't be rendered (too large, blank) is skipped, so the extraction
          # is incomplete rather than lost. Before any answer, the caller tries another way.
          raise if values.empty? && !answered_before

          log_unanswered(slice)
          [ [], [] ]
        rescue *Ai::DownMarks::PASSING
          # An outage on a later batch doesn't throw away what the earlier batches answered; the
          # failed slice waits for the later job, like a failover part-way through a slice.
          raise if values.empty?

          remaining = slice + (remaining[slice.size..] || [])
          break
        end
        answers.each do |by, value|
          served = by
          Array(value[merge_key]).each { answered_by[_1[merge_by]] = by } if merge_key
          values << value
        end
        log_omitted(slice - unanswered, values)
        remaining = unanswered + (remaining[slice.size..] || [])   # by position: two equal units are two inputs
        done += 1
        break if unanswered.any?   # the routes failed over; a later job retries these
      end

      result(value: merge_values(values), route: served, remaining:, answered_by:)
    end

    # Runs `slice` (nil for a feature without items) down the routes: failover and escalation
    # move on, an overflow is split on the same route. Returns [[[route, value], ...], unanswered]:
    # one pair per piece the slice was split into, in the slice's order, and the items to retry
    # later. Those are kept when a route failed over or was marked down, since it might still
    # answer them; otherwise items no route could fit or answer are left out.
    def on_routes(routes, slice)
      pending = slice
      pending_positions = pending ? pending.each_index.to_a : []   # each pending item's original position
      pending_offset = 0
      # split_on labels answers from pending_offset; translate them back to original positions so
      # a noncontiguous pending run (a and d left, b and c answered) can't reorder the merge.
      remap = ->(pairs, base) { pairs.map { |value, at| [ pending_positions[at - base] || at, value ] } }
      refresh_positions = -> { pending_positions = pending ? pending.map { position_of(_1, slice) } : [] }
      answers = []   # [position, route, value], so a recovered earlier piece keeps its place
      last_error = nil
      transient = false
      passing = nil   # a failure that passes on its own: with no answer, the call is retried, not the items skipped
      needs_fix = nil   # one that doesn't (a bad key, no credit, a missing model): with no answer, the run ends on it
      unusable, unusable_on = nil, nil   # the first unusable answer, and the route bisection retries in halves
      # Equal positions keep the order they were answered in, so normal in-order runs don't move.
      ordered = -> { answers.each_with_index.sort_by { |(answer, i)| [ answer.first, i ] }.map { |(answer, _)| answer.drop(1) } }

      failed = lambda do |route, error|
        last_error = error
        if error.is_a?(Ai::Error::InvalidOutput)
          unusable ||= error
          unusable_on ||= route
        elsif Ai::DownMarks::FAILOVER.any? { error.is_a?(_1) }
          fail_over(route, error)
          transient = true
          if Ai::DownMarks::PASSING.any? { error.is_a?(_1) }
            passing ||= error
          else
            needs_fix ||= error
          end
        end
      end

      routes.each do |route|
        state = @down_marks.state(route)
        unless state == :up
          transient = true
          down = "#{route.endpoint.name}/#{route.model.name} is marked down"
          if state == :passing
            passing ||= Ai::Error::Unreachable.new(down)
          else
            needs_fix ||= Ai::Error::Refused.new("#{down} for a failure that needs a fix")
          end
          next
        end

        begin
          done, pending = split_pending_runs(route, pending, pending_positions, pending_offset)
          answers.concat(remap.call(done, pending_offset).map { |at, value| [ at, route, value ] })
          refresh_positions.call
          pending_offset = position_of(pending.first, slice) if pending.any?
          return [ ordered.call, [] ] if pending.empty?
        rescue Interrupted => partial
          answers.concat(remap.call(partial.values, pending_offset).map { |at, value| [ at, route, value ] })
          pending = partial.pending
          refresh_positions.call
          pending_offset = position_of(pending.first, slice) if pending.any?
          failed.call(route, partial.error)
        rescue *Ai::DownMarks::FAILOVER, Ai::Error::InvalidOutput, Ai::Error::ContextTooLong, Ai::Error::UnsupportedInput => error
          failed.call(route, error)
        end
      end

      # A route found the answer unusable and none answered the rest: one odd transaction can derail
      # a model, so look for it by halving on that route, rather than lose the whole batch. A later
      # route that couldn't fit the batch doesn't change that.
      if unusable_on && pending && pending.size > 1 && @down_marks.state(route = unusable_on) == :up
        begin
          done, pending = bisect_pending_runs(route, pending, pending_positions, pending_offset)
          answers.concat(remap.call(done, pending_offset).map { |at, value| [ at, route, value ] })
          refresh_positions.call
          pending_offset = position_of(pending.first, slice) if pending.any?
        rescue Interrupted => partial
          answers.concat(remap.call(partial.values, pending_offset).map { |at, value| [ at, route, value ] })
          pending = partial.pending
          refresh_positions.call
          pending_offset = position_of(pending.first, slice) if pending.any?
          failed.call(route, partial.error)
        rescue *Ai::DownMarks::FAILOVER => error
          failed.call(route, error)
        end
      end

      # Part of the slice was answered: keep the answers. The rest is retried later when a route
      # failed over or was down (a timeout, an outage), and left unanswered when it fits no route,
      # breaks every answer or can't take the input.
      if answers.any?
        return [ ordered.call, pending ] if transient

        log_unanswered(pending)
        return [ ordered.call, [] ]
      end

      # A later route that couldn't fit the slice doesn't hide why the earlier ones failed: an unusable
      # answer still fails like one, and a failure that needs a fix (a bad key) reaches the requester
      # instead of the slice being skipped (Ai::Generation#call_batched). With no route tried, a
      # failure that needs a fix still ends the run rather than being retried as an outage.
      unfit = last_error.is_a?(Ai::Error::ContextTooLong)
      raise passing || (unusable if unfit) || (needs_fix if unfit) || last_error || needs_fix ||
            Ai::Error::Unreachable.new("every route for #{feature_key} is marked down")
    end

    # Where a pending item started in the original slice, after a route answered only part of it.
    def position_of(item, slice)
      return 0 unless slice

      slice.index { _1.equal?(item) } || slice.index(item) || 0
    end

    def fail_over(route, error)
      @down_marks.mark(route, error)
      error
    end

    # A pending array can be noncontiguous in the original slice (b and c answered, a and d
    # left). split_on numbers a whole answer from one offset, so sending [a, d] as one request
    # would put both values at a's position. Request each contiguous run separately, with the
    # offset it had in `pending`, so the existing remap still restores original positions.
    def split_pending_runs(route, pending, positions, offset)
      return split_on(route, nil, offset) if pending.nil?

      runs, starts = contiguous_runs(pending, positions, offset)
      values, unfit = answer_pieces(route, runs, offset, offsets: starts)
      raise Interrupted.new(values, unfit.flatten(1), Ai::Error::ContextTooLong.new("a pending run doesn't fit #{route.model.name}")) if unfit.any?

      [ values, [] ]
    end

    # The same for the bisection retry: each run is halved on its own, so a half never joins
    # items that weren't adjacent in the slice.
    def bisect_pending_runs(route, pending, positions, offset)
      runs, starts = contiguous_runs(pending, positions, offset)
      each_piece(runs, offset, offsets: starts) { |run, at| bisect(route, run, 1, at) }
    end

    # [runs of `pending` adjacent in the slice, each run's offset in `pending`].
    def contiguous_runs(pending, positions, offset)
      runs, starts, index = [], [], 0
      while index < pending.size
        finish = index + 1
        finish += 1 while finish < pending.size && positions[finish] == positions[finish - 1] + 1
        runs << pending[index...finish]
        starts << offset + index
        index = finish
      end
      [ runs, starts ]
    end

    # Answers `slice` on one route: in pieces of the route's batch_size when it holds more (a
    # fallback can take fewer items than the route the slice was sized for), halved on overflow.
    # Returns [[value, position] pairs, items it couldn't fit or answer], or raises when nothing
    # could be answered. Positions are relative to `slice`, so a piece recovered later by another
    # route can be put back where it belongs.
    def split_on(route, slice, offset = 0)
      cap = route.model.batch_size
      return answer_pieces(route, slice.each_slice(cap).to_a, offset) if slice && slice.size > cap

      answer_whole(route, slice, offset)
    end

    def answer_whole(route, slice, offset = 0)
      [ [ [ run(route, slice), offset ] ], [] ]
    rescue Ai::Error::ContextTooLong
      raise if slice.nil? || slice.size <= 1

      answer_pieces(route, Ai::Batch.halves(slice), offset)
    end

    def answer_pieces(route, pieces, offset = 0, offsets: nil)
      values, unfit = each_piece(pieces, offset, offsets:) do |piece, at|
        split_on(route, piece, at)
      rescue Ai::Error::ContextTooLong
        [ [], piece ]   # a single item that can't fit here
      end
      raise Ai::Error::ContextTooLong, "no item of the batch fits #{route.model.name}" if values.empty?

      [ values, unfit ]
    end

    # Answers what it can of `items` on one route by halving them at most BISECT_DEPTH times.
    # Returns [[value, position] pairs, items left unanswered]. A model that answers nothing usable
    # stops at the cap, so it costs a few calls, not one per item.
    def bisect(route, items, depth = 1, offset = 0)
      each_piece(Ai::Batch.halves(items), offset) do |half, at|
        split_on(route, half, at)
      rescue Ai::Error::InvalidOutput, Ai::Error::UnsupportedInput
        depth < BISECT_DEPTH && half.size > 1 ? bisect(route, half, depth + 1, at) : [ [], half ]
      rescue Ai::Error::ContextTooLong
        [ [], half ]
      end
    end

    # Gathers the block's [[value, position] pairs, items left] over `pieces`. An unusable or
    # unsupported answer leaves its piece and the others go on, wherever it falls, so the outcome
    # doesn't depend on item order; at the end it raises Interrupted with the answers, so the route
    # can still be bisected, or the error itself when nothing was answered. A failover raises
    # Interrupted at once, with everything still unanswered, or propagates as it is before any answer.
    def each_piece(pieces, offset = 0, offsets: nil)
      values, left, unusable = [], [], nil
      at = offset
      pieces.each_with_index do |piece, i|
        starting_at = offsets ? offsets[i] : at
        at = starting_at + piece.size
        answered, rest = yield(piece, starting_at)
        values.concat(answered)
        left.concat(rest)
      rescue Ai::Error::InvalidOutput, Ai::Error::UnsupportedInput => error
        left.concat(piece)
        unusable ||= error
      rescue Interrupted => partial
        unless partial.error.is_a?(Ai::Error::InvalidOutput) || partial.error.is_a?(Ai::Error::UnsupportedInput)
          raise Interrupted.new(values + partial.values, left + partial.pending + pieces.drop(i + 1).flatten(1), partial.error)
        end

        values.concat(partial.values)
        left.concat(partial.pending)
        unusable ||= partial.error
      rescue *Ai::DownMarks::FAILOVER => error
        raise if values.empty?

        raise Interrupted.new(values, left + pieces.drop(i).flatten(1), error)
      end
      raise unusable if unusable && values.empty?
      raise Interrupted.new(values, left, unusable) if unusable

      [ values, left ]
    end

    def run(route, slice)
      generation = slice ? with_items(slice) : self
      return judge(route, generation) if route.judge?

      prompt = Ai::Prompt.for(feature_key, default: prompt_key, route:, family:, locale: prompt_locale, locals: generation.prompt_locals)
      request = Ai::Transport::Base::Request.new(
        feature: request_feature, family:, model: route.model, instructions: prompt.instructions, input: prompt.input,
        schema: generation.schema, schema_name: schema_label || feature_key, reasoning_effort: route.reasoning_effort,
        json_mode: route.effective_json_mode, failed_ratio: (generation.method(:failed_ratio) if batch_key && blank_item_check),
        attachments: generation.attachments
      )
      generation.coerce(route.transport.generate(request).json)
    end

    def judge(route, generation)
      judgement_class.new(**generation.arguments, family:).run(route, feature: request_feature)
    end

    # Items the answer left out: an answer missing up to half of its items is still accepted.
    def log_omitted(items, values)
      return unless merge_key   # one answer for the whole batch, with nothing to leave out

      answered_ids = values.flat_map { Array(_1[merge_key]) }.map { _1[merge_by].to_s }
      log_unanswered(items.reject { answered_ids.include?(item_id(_1).to_s) })
    end

    # Ids only: the items themselves hold the family's data. A unit can be reported by both
    # on_routes and log_omitted in one slice; count it once, but keep separate units that happen
    # to be equal. Only the first skip of a given id gets a log entry.
    def log_unanswered(items)
      fresh_units = items.reject { @skipped_in_slice.include?(_1.object_id) }
      return if fresh_units.empty?

      @skipped_in_slice.merge(fresh_units.map(&:object_id))
      @skipped.concat(fresh_units)
      fresh_ids = fresh_units.map { item_id(_1) }.uniq.reject { @logged_ids.include?(_1) }
      return if fresh_ids.empty?

      @logged_ids.merge(fresh_ids)
      DebugLogEntry.capture(
        category: "ai_generation", level: "warn", message: "Items no route could answer were left unanswered",
        source: self.class.name, family:, metadata: { feature: feature_key.to_s, item_ids: fresh_ids }
      )
    end

    # A hash item's id, or what an item object logs as (Ai::PdfReading::Unit#log_id).
    def item_id(item) = item.is_a?(Hash) ? item[:id] : item.log_id

    # The tokens the prompt takes before any item: rendered once per route with no items. A judge
    # model has no prompt.
    def fixed_tokens(route)
      return 0 if route.judge?

      @fixed_tokens ||= {}
      @fixed_tokens[route] ||= begin
        empty = with_items([])
        prompt = Ai::Prompt.for(feature_key, default: prompt_key, route:, family:, locale: prompt_locale, locals: empty.prompt_locals)
        Assistant::TokenEstimator.estimate(prompt.instructions) + Assistant::TokenEstimator.estimate(prompt.input) +
          Assistant::TokenEstimator.estimate(empty.schema)
      end
    end

    # The feature the call is recorded under: shadow_<feature> on a shadow run, so its usage is its own.
    def request_feature = @recorded_feature || feature_key

    def shadow_run? = request_feature != feature_key

    # The user's locale when a user started the work, otherwise the family's.
    def prompt_locale = user&.locale.presence || family&.locale.presence

    def result(value:, route:, remaining: [], answered_by: {})
      Ai::Result.new(value:, route:, remaining:, answered_by:, skipped: @skipped.dup)
    end
end
