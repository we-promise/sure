require "test_helper"

# `loan.amortizations` is a CACHE, valid only while `schedule_current?`.
#
# Since #39 no read path rebuilds it, so any surface reading it directly is
# reading a cache it has not checked. Four separate surfaces made that mistake
# before this guard existed -- the schedule table (#39), the payoff projection
# (#35 x #39), the Overview payoff-date card (#7) and the payoff chart (#52) --
# each producing the same silent failure: two different loans' numbers on one
# screen, with no exception and no failing test (risk R21).
#
# `Loan::AmortizationSchedule#display_rows` hides the distinction: persisted
# rows when they are current, recomputed in memory when they are not. This test
# makes reaching past it a build failure rather than a review catch (#56).
class Loan::AmortizationsReadGuardTest < ActiveSupport::TestCase
  # Exemptions are per METHOD, never per file.
  #
  # A file-wide exemption would let a new method in an already-permitted file
  # read the cache silently -- and that is not hypothetical: #payoff_chart_payload
  # in loan.rb was the fourth defect, in the file that most obviously owns the
  # association.
  PERMITTED_METHODS = {
    "app/models/loan.rb" => {
      reason: "Owns the cache: the rebuild/delete write paths and the freshness " \
              "checks that decide whether it may be trusted.",
      methods: %w[
        rebuild_amortization_schedule
        rebuild_amortization_schedule_locked!
        ensure_amortization_schedule_current!
        schedule_current?
        schedule_current_for_signature?
        reset_amortizations_association!
      ],
      # The association declaration itself. Narrow on purpose: anything else at
      # class-body level -- a scope, a delegate, a constant -- is still caught.
      outside_methods: [ /\Ahas_many :amortizations,/ ]
    },
    "app/models/loan/amortization_schedule.rb" => {
      reason: "#display_rows is the sanctioned reader -- the one place allowed " \
              "to choose between persisted and recomputed rows.",
      methods: %w[display_rows]
    },
    "app/controllers/api/v1/loans_controller.rb" => {
      reason: "Reads persisted rows deliberately AND declares their freshness " \
              "to the caller, so the consumer is never misled about what it got.",
      methods: %w[amortization_schedule amortization_schedule_status]
    }
  }.freeze

  # Templates have no methods to name, so they are exempted as a whole -- but
  # only on condition that they carry the freshness declaration themselves.
  PERMITTED_TEMPLATES = {
    "app/views/api/v1/loans/amortization_schedule.json.jbuilder" =>
      "Renders the API response above; the exemption holds only while it emits `status`."
  }.freeze

  test "no unapproved code reads the persisted association" do
    offenders = []

    Dir.glob(Rails.root.join("app/**/*.{rb,erb,jbuilder}")).sort.each do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if relative == "app/models/loan_amortization.rb"
      next if PERMITTED_TEMPLATES.key?(relative)

      source = strip_comments(File.read(path))
      next unless source.match?(/\bamortizations\b/)

      allowed = PERMITTED_METHODS.dig(relative, :methods)
      if allowed.nil?
        offenders << relative
        next
      end

      # Anything outside a def -- class body, constants, scopes -- counts as
      # unapproved: only named methods can be reasoned about.
      bodies, top_level = definitions_in(path)
      permitted_outside = PERMITTED_METHODS.dig(relative, :outside_methods) || []
      stray = strip_comments(top_level).lines.map(&:strip).select { |line| line.match?(/\bamortizations\b/) }
      stray.reject! { |line| permitted_outside.any? { |pattern| line.match?(pattern) } }
      offenders << "#{relative} (outside any method: #{stray.first})" if stray.any?
      bodies.each do |name, body|
        next if allowed.include?(name)
        next unless strip_comments(body).match?(/\bamortizations\b/)

        offenders << "#{relative}##{name}"
      end
    end

    assert_empty offenders, <<~MESSAGE
      These read `loan.amortizations` without approval:

        #{offenders.join("\n  ")}

      That association is a cache, valid only while `schedule_current?`, and no
      read path rebuilds it since #39. Read
      `Loan::AmortizationSchedule#display_rows` instead -- persisted rows when
      current, recomputed when not.

      If a surface genuinely must read persisted rows it has to DECLARE their
      freshness, the way the API does with `status`, and be named in
      PERMITTED_METHODS with a reason.
    MESSAGE
  end

  test "the API exemption holds only while the response declares freshness" do
    PERMITTED_TEMPLATES.each_key do |relative|
      source = Rails.root.join(relative).read

      assert_match(/\bstatus\b/, source,
        "#{relative} is exempted because it declares freshness. It no longer emits `status`, " \
        "so the exemption no longer applies -- either restore it or remove the exemption.")
    end

    controller = Rails.root.join("app/controllers/api/v1/loans_controller.rb").read
    assert_match(/status:/, controller,
      "the API exemption rests on the response carrying a freshness status")
  end

  test "every exemption still applies and none has gone stale" do
    PERMITTED_METHODS.each do |relative, entry|
      full = Rails.root.join(relative)
      assert full.file?, "PERMITTED_METHODS lists #{relative}, which no longer exists -- prune it"
      assert entry[:reason].present?, "#{relative} needs a reason"

      bodies, = definitions_in(full.to_s)
      entry[:methods].each do |name|
        assert bodies.key?(name),
          "PERMITTED_METHODS names #{relative}##{name}, which no longer exists -- prune it"
      end
    end

    PERMITTED_TEMPLATES.each do |relative, reason|
      assert Rails.root.join(relative).file?, "PERMITTED_TEMPLATES lists #{relative}, which no longer exists"
      assert reason.present?, "#{relative} needs a reason"
    end
  end

  private

    # Splits a Ruby file into method name => body, plus everything outside any
    # method. Handles `def self.x` as well as `def x`: a singleton method that
    # read the cache would otherwise never be inspected.
    def definitions_in(path)
      bodies = {}
      top_level = +""
      current = nil
      indent = nil

      File.readlines(path).each do |line|
        if (match = line.match(/^(\s*)def (?:self\.)?([a-zA-Z_][\w?!=]*)/))
          indent = match[1]
          current = match[2]
          bodies[current] = +""
        elsif current && line.rstrip == "#{indent}end"
          current = nil
        elsif current
          bodies[current] << line
        else
          top_level << line
        end
      end

      [ bodies, top_level ]
    end

    # Comments do not count: a file may name the association to explain why it
    # deliberately does not use it -- `_overview.html.erb` does exactly that.
    def strip_comments(source)
      source
        .gsub(/<%#.*?%>/m, "")
        .lines
        .reject { |line| line.strip.start_with?("#") }
        .join
    end
end
