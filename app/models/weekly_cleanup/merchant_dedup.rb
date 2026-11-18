# Deterministic merchant de-duplication: name normalization + character-trigram
# (Jaccard) similarity, clustered with union-find. No LLM, no DB extensions —
# pure Ruby so it behaves identically on every install.
#
# Result carries the total merchant count plus the duplicate clusters so the
# report can present "351 merchants, 12 duplicate clusters (3.4% clustered)"
# style coverage.
class WeeklyCleanup::MerchantDedup
  # Common business suffixes that rarely distinguish the actual merchant.
  SUFFIXES = %w[
    inc llc ltd ll lp llp corp corporation co company gmbh sarl sas bv nv ag
    sa spa plc pty limited group holdings international intl
  ].freeze

  SIMILARITY_THRESHOLD = 0.6

  Result = Data.define(:total, :clustered, :clusters) do
    def coverage_pct
      return 0 if total.zero?

      (clustered.to_f / total * 100).round(1)
    end
  end

  Cluster = Data.define(:members, :normalized_name)

  def self.call(merchants)
    new(merchants).call
  end

  def initialize(merchants)
    @merchants = merchants.to_a
  end

  def call
    normalized = @merchants.map { |m| [ m, self.class.normalize(m.name) ] }
    # Skip merchants whose name normalizes to nothing (e.g. "###").
    normalized = normalized.reject { |_, n| n.blank? }

    parent = {}
    find = ->(x) {
      root = x
      root = parent[root] while parent[root] && parent[root] != root
      # path compression
      while parent[x] && parent[x] != x
        parent[x], x = root, parent[x]
      end
      root
    }
    union = ->(a, b) { parent[find.(a)] = find.(b) }

    # Bucket by first trigram-rich token to avoid full O(n^2) on huge lists:
    # only names sharing at least one token can reach the threshold anyway.
    tokens = normalized.to_h { |m, n| [ m.object_id, n.split ] }
    normalized.combination(2) do |(ma, na), (mb, nb)|
      next if (tokens[ma.object_id] & tokens[mb.object_id]).empty? && na != nb

      if na == nb || jaccard(trigrams(na), trigrams(nb)) >= SIMILARITY_THRESHOLD
        union.(ma.object_id, mb.object_id)
      end
    end

    groups = normalized.group_by { |m, _| find.(m.object_id) }.values
    clusters = groups.select { |g| g.size > 1 }.map do |group|
      members = group.map(&:first).sort_by(&:name)
      Cluster.new(members: members, normalized_name: self.class.normalize(members.first.name))
    end.sort_by { |c| -c.members.size }

    Result.new(
      total: @merchants.size,
      clustered: clusters.sum { |c| c.members.size },
      clusters: clusters
    )
  end

  def self.normalize(name)
    s = name.to_s.downcase
    s = s.gsub(/&/, " and ")
    s = s.gsub(/[^a-z0-9\s]/, " ")      # punctuation (incl. store #1234) -> space
    s = s.gsub(/\b\d{3,}\b/, " ")        # long store/location numbers carry no brand signal
    words = s.split - SUFFIXES
    words.join(" ").squish
  end

  private
    def trigrams(str)
      padded = "  #{str} "
      padded.chars.each_cons(3).map(&:join).to_set
    end

    def jaccard(a, b)
      return 1.0 if a == b
      return 0.0 if a.empty? || b.empty?

      (a & b).size.to_f / (a | b).size
    end
end
