class Entry::NameSuggestions
  DEFAULT_LIMIT = 8
  MIN_QUERY_LENGTH = 2
  MAX_QUERY_LENGTH = 100
  NORMALIZED_NAME_SQL = "lower(regexp_replace(trim(entries.name), ' +', ' ', 'g'))"

  attr_reader :scope, :query, :limit

  def initialize(scope:, query:, limit: DEFAULT_LIMIT)
    @scope = scope
    @query = query.to_s.squish
    @limit = limit.to_i
  end

  def call
    return [] if query.length < MIN_QUERY_LENGTH
    return [] if query.length > MAX_QUERY_LENGTH

    Entry.connection.select_values(suggestions_sql)
  end

  private
    def suggestions_sql
      sanitize_sql([
        <<~SQL.squish,
          WITH candidates AS (#{candidate_scope.to_sql}),
          variant_stats AS (
            SELECT
              normalized_name,
              name,
              COUNT(*) AS variant_count,
              MAX(created_at) AS variant_latest_seen_at,
              MIN(transaction_name_match_rank) AS variant_match_rank
            FROM candidates
            GROUP BY normalized_name, name
          ),
          canonical_variants AS (
            SELECT DISTINCT ON (normalized_name)
              normalized_name,
              name AS canonical_name
            FROM variant_stats
            ORDER BY normalized_name, variant_count DESC, variant_latest_seen_at DESC, name ASC
          ),
          normalized_stats AS (
            SELECT
              normalized_name,
              MAX(variant_latest_seen_at) AS latest_seen_at,
              MIN(variant_match_rank) AS match_rank
            FROM variant_stats
            GROUP BY normalized_name
          )
          SELECT canonical_variants.canonical_name
          FROM normalized_stats
          JOIN canonical_variants USING (normalized_name)
          ORDER BY normalized_stats.match_rank ASC, normalized_stats.latest_seen_at DESC, canonical_variants.canonical_name ASC
          LIMIT ?
        SQL
        result_limit
      ])
    end

    def candidate_scope
      scope
        .where(entryable_type: "Transaction", parent_entry_id: nil)
        .where.not(name: [ nil, "" ])
        .where(similarity_condition)
        .select(
          "entries.name",
          "entries.created_at",
          "#{NORMALIZED_NAME_SQL} AS normalized_name",
          "#{match_rank_sql} AS transaction_name_match_rank"
        )
    end

    def similarity_condition
      sanitize_sql([ "#{NORMALIZED_NAME_SQL} % ?", normalized_query ])
    end

    def match_rank_sql
      sanitize_sql([
        <<~SQL.squish,
          CASE
            WHEN #{NORMALIZED_NAME_SQL} = ? THEN 0
            WHEN #{NORMALIZED_NAME_SQL} LIKE ? THEN 1
            WHEN #{NORMALIZED_NAME_SQL} LIKE ? THEN 2
            ELSE 3
          END
        SQL
        normalized_query,
        "#{escaped_query}%",
        "% #{escaped_query}%"
      ])
    end

    def normalized_query
      @normalized_query ||= query.downcase
    end

    def escaped_query
      @escaped_query ||= ActiveRecord::Base.sanitize_sql_like(normalized_query)
    end

    def result_limit
      limit.positive? ? limit : DEFAULT_LIMIT
    end

    def sanitize_sql(args)
      ActiveRecord::Base.sanitize_sql_array(args)
    end
end
