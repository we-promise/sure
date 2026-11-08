# The base class of every structured-output feature. A feature is declared, not
# implemented: its key, its prompt folder, its schema and, when it takes a list, how the list is
# batched and merged. `call` is the only place that does the rest, in this order:
#
#   1. Ai::Router#resolve(feature); unavailable returns Ai::Result.unavailable(reason).
#   2. Stop if `cancelled` returns true, here and before every batch.
#   3. Take the first route not marked down (Ai::DownMarks). Render its prompt (Ai::Prompt), take
#      the next batch sized for its model (Ai::Batch), call its transport's `generate`, and
#      coerce the answer (Ai::Schema).
#   4. On a failover error (Ai::DownMarks::FAILOVER), mark it down and take the next route. On
#      InvalidOutput, escalate to the next route. On ContextTooLong or an answer cut at the
#      output limit, halve the batch on the same route; a single item that still can't fit
#      escalates. Nothing else is retried here; the transport has retried 429s and 5xxs.
#   5. Return an Ai::Result with the route that answered and the items not reached.
#
# `call(batches: 1)` runs one batch, which is what Ai::GenerationJob does (small batches,
# so other work takes turns); plain `call` runs them all and merges the answers. `call!` returns the value or
# raises the Ai::Error, for jobs.
class Ai::Generation
  class_attribute :feature_key, :prompt_key, :static_schema, :schema_label, :batch_key, :merge_key, :merge_by,
                  :blank_item_check, :key_aliases, :required_keys, instance_writer: false

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

    # An item the model left blank, for `auto` JSON mode's fallback (today's null heuristics).
    def blank_item(&check) = self.blank_item_check = check

    # Field names models use instead of the schema's, as today's parsers accept them.
    def aliases(map) = self.key_aliases = map

    # Item fields without which an answer can't be matched to its input.
    def required(*keys) = self.required_keys = keys.map(&:to_sym)
  end

  attr_reader :family, :user, :locale

  def initialize(family:, user: nil, locale: nil)
    @family, @user, @locale = family, user, locale
  end

  def schema = static_schema

  # Locals for the prompt templates; a batched feature includes its items.
  def prompt_locals = {}

  # Fields the feature matches itself instead of by the schema's enum (Ai::Schema's `match:`).
  def matchers = {}

  def items = batch_key ? Array(instance_variable_get(:"@#{batch_key}")) : nil

  # A copy holding only `slice`, so prompt_locals only ever sees one batch.
  def with_items(slice) = dup.tap { _1.instance_variable_set(:"@#{batch_key}", slice) }

  def call!(...) = call(...).value!

  def call(batches: nil, cancelled: nil, plan: nil)
    plan ||= Ai::Router.new(family:, user:).resolve(feature_key)
    return Ai::Result.unavailable(plan) unless plan.is_a?(Ai::Plan)

    routes = plan.routes.select { !_1.judge? && _1.model.capable?(:structured_output) }
    return Ai::Result.unavailable(Ai::Availability.unavailable(feature_key, :capability_missing)) if routes.empty?

    @usage = nil
    @failed_over_from = []
    batch_key ? call_batched(routes, batches:, cancelled:) : call_single(routes, cancelled:)
  rescue Ai::Error::Base => error
    Ai::Result.failure(error, usage: @usage, failed_over_from: @failed_over_from.presence, correlation_id: Ai::CallContext.correlation_id)
  end

  # The share of this batch's items the model left blank or missed.
  def failed_ratio(json)
    return 0.0 unless blank_item_check && items.any?

    answered = Array(coerce(json)[merge_key])
    blank = answered.count { blank_item_check.call(_1) }
    (blank + [ items.size - answered.size, 0 ].max) / items.size.to_f
  rescue Ai::Error::InvalidOutput
    1.0
  end

  def coerce(json)
    Ai::Schema.coerce(json, schema, aliases: key_aliases || {}, match: matchers, required: required_keys || [])
  end

  private
    def call_single(routes, cancelled:)
      raise Ai::Error::Cancelled, "cancelled" if cancelled&.call

      route, value = on_routes(routes, nil).first
      result(value:, route:)
    end

    def call_batched(routes, batches:, cancelled:)
      remaining = items.dup
      answered = []
      served = nil
      done = 0

      while remaining.any? && (batches.nil? || done < batches)
        raise Ai::Error::Cancelled, "cancelled" if cancelled&.call

        route = routes.find { !Ai::DownMarks.down?(_1) } || routes.first
        slice = Ai::Batch.first_slice(remaining, model: route.model, fixed_tokens: fixed_tokens(route))
        on_routes(routes, slice).each do |answered_by, value|
          served = answered_by
          answered.concat(Array(value[merge_key]))
        end
        remaining -= slice
        done += 1
      end

      result(value: { merge_key => answered.index_by { _1[merge_by] }.values }, route: served, remaining:)
    end

    # Runs `slice` (nil for a feature without items) down the routes: failover and escalation
    # move on, an overflow is split on the same route. Returns [[route, value], ...], one pair
    # per piece the slice was split into.
    def on_routes(routes, slice)
      pending = slice
      answers = []
      last_error = nil

      routes.each do |route|
        next if Ai::DownMarks.down?(route)

        begin
          done, pending = split_on(route, pending)
          answers.concat(done.map { [ route, _1 ] })
          return answers if pending.empty?
        rescue *Ai::DownMarks::FAILOVER => error
          Ai::DownMarks.mark(route, error)
          @failed_over_from << route
          last_error = error
        rescue Ai::Error::InvalidOutput, Ai::Error::ContextTooLong => error
          last_error = error
        end
      end

      raise last_error || Ai::Error::Unreachable.new("every route for #{feature_key} is marked down")
    end

    # Answers `slice` on one route, halving it on overflow. Returns [values, items that can't
    # fit on their own], or raises when nothing in the slice could be answered here.
    def split_on(route, slice)
      [ [ run(route, slice) ], [] ]
    rescue Ai::Error::ContextTooLong
      raise if slice.nil? || slice.size <= 1

      values, unfit = Ai::Batch.halves(slice).each_with_object([ [], [] ]) do |half, (done, left)|
        answered, rest = split_on(route, half)
        done.concat(answered)
        left.concat(rest)
      rescue Ai::Error::ContextTooLong
        left.concat(half)   # a single item that can't fit here
      end
      raise Ai::Error::ContextTooLong, "no item of the batch fits #{route.model.name}" if values.empty?

      [ values, unfit ]
    end

    def run(route, slice)
      generation = slice ? with_items(slice) : self
      prompt = Ai::Prompt.for(feature_key, default: prompt_key, route:, family:, locale: prompt_locale, locals: generation.prompt_locals)
      request = Ai::Transport::Base::Request.new(
        feature: feature_key, family:, model: route.model, instructions: prompt.instructions, input: prompt.input,
        schema: generation.schema, schema_name: schema_label || feature_key, reasoning_effort: route.reasoning_effort,
        json_mode: route.effective_json_mode, failed_ratio: (generation.method(:failed_ratio) if batch_key && blank_item_check)
      )
      response = route.transport.generate(request)
      @usage = @usage ? @usage + response.usage : response.usage
      generation.coerce(response.json)
    end

    # The tokens the prompt takes before any item: rendered once per route with no items.
    def fixed_tokens(route)
      @fixed_tokens ||= {}
      @fixed_tokens[route] ||= begin
        empty = with_items([])
        prompt = Ai::Prompt.for(feature_key, default: prompt_key, route:, family:, locale: prompt_locale, locals: empty.prompt_locals)
        Assistant::TokenEstimator.estimate(prompt.instructions) + Assistant::TokenEstimator.estimate(prompt.input) +
          Assistant::TokenEstimator.estimate(empty.schema)
      end
    end

    # The user's locale when a user started the work, otherwise the family's.
    def prompt_locale = locale || user&.locale.presence || family&.locale.presence

    def result(value:, route:, remaining: [])
      Ai::Result.new(value:, usage: @usage, route:, failed_over_from: @failed_over_from.presence, remaining:,
                     correlation_id: Ai::CallContext.correlation_id)
    end
end
