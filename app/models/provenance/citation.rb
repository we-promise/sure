# frozen_string_literal: true

# Value object for the citation grammar that agent-recorded values must follow:
#
#   source := ["estimated: "] citation [" (grade: " ("A"|"B"|"C") ")"]
#
# e.g. "Private bank integrated statement 2026-03-31, category subtotals (grade: A)"
#      "estimated: linear interpolation over 2024-08 / 2024-12 anchors (grade: C)"
#
# A citation is the only thing separating a sourced number from an invented one,
# so the grammar is parsed rather than trusted. A free-styled string is rejected
# at the write boundary instead of landing in the ledger looking authoritative,
# and an estimate can never lose its marker on the way in.
module Provenance
  class Citation
    ESTIMATED_PREFIX = "estimated: "
    GRADES = %w[A B C].freeze
    MIN_TEXT_LENGTH = 3
    MAX_LENGTH = 500

    # Spacing around the grade is tolerated (\s? before the paren, \s* after the
    # colon) so the suffix is recognised wherever GRADE_SUFFIX recognises it. The
    # two patterns must stay in sync: if FORMAT is the stricter of the pair, a
    # citation like "Doc (grade:A)" passes the suffix pre-check and then fails to
    # match here, folding the grade into the citation text and yielding an
    # ungraded source — silently losing the reliability the caller supplied.
    FORMAT = /\A(?<estimated>estimated:\s)?(?<text>.+?)(?:\s?\(grade:\s*(?<grade>[ABC])\))?\z/
    # Matched separately so "(grade: D)" fails loudly instead of folding into the
    # citation text and passing as an ungraded — but plausible-looking — source.
    GRADE_SUFFIX = /\(grade:\s*(?<grade>[^)]*)\)\s*\z/
    ESTIMATED_MARKER = /\Aestimated\s*:/i

    class InvalidError < StandardError; end

    attr_reader :raw, :text, :grade

    class << self
      # Returns a Citation, or raises InvalidError with a message written for the
      # caller that has to fix it (an agent, usually).
      def parse!(raw)
        value = raw.to_s.strip

        raise InvalidError, "source citation is required" if value.blank?
        raise InvalidError, "source citation must be #{MAX_LENGTH} characters or fewer" if value.length > MAX_LENGTH

        if value.match?(ESTIMATED_MARKER) && !value.start_with?(ESTIMATED_PREFIX)
          raise InvalidError, "estimated values must start with the exact prefix #{ESTIMATED_PREFIX.inspect}"
        end

        if (suffix = value.match(GRADE_SUFFIX)) && !GRADES.include?(suffix[:grade])
          raise InvalidError, "reliability grade must be one of #{GRADES.join(", ")} (got #{suffix[:grade].inspect})"
        end

        match = value.match(FORMAT)
        raise InvalidError, "source citation does not match #{grammar}" unless match

        text = match[:text].to_s.strip
        if text.length < MIN_TEXT_LENGTH
          raise InvalidError, "source citation must name the document it came from"
        end

        estimated = match[:estimated].present?
        grade = match[:grade]

        if estimated && grade.blank?
          raise InvalidError, "estimated values must carry a reliability grade, e.g. \"#{ESTIMATED_PREFIX}... (grade: C)\""
        end

        new(raw: value, text: text, estimated: estimated, grade: grade)
      end

      def valid?(raw)
        parse!(raw)
        true
      rescue InvalidError
        false
      end

      def grammar
        %(["#{ESTIMATED_PREFIX}"] citation [" (grade: #{GRADES.join("|")})"])
      end
    end

    def initialize(raw:, text:, estimated:, grade:)
      @raw = raw
      @text = text
      @estimated = estimated
      @grade = grade
    end

    def estimated?
      @estimated
    end

    # Reliability C is a standing TODO: a proxy or assumption that should be
    # re-derived from a primary source rather than left to age in place.
    def proxy?
      grade == "C"
    end

    def to_s
      raw
    end

    def to_h
      { source: raw, citation: text, estimated: estimated?, grade: grade }
    end
  end
end
