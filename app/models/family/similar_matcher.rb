# Finds near-duplicates of a transaction in a pool by its description:
# TF-IDF cosine over its words and, separately, its character 3-grams, so
# "NETFLIX.COM 8812" and "Netflix com" match. Numbers and reference codes
# are dropped first, so they don't make one shop's lines look different or
# two shops' look alike. Used by Family::SimilarMerchantFiller to copy a
# merchant every confirmed near-duplicate agrees on.
class Family::SimilarMatcher
  # The cutoff (common_share) is never below this many transactions, so a
  # small pool keeps a monthly bill.
  MIN_DOCUMENT_CAP = 50
  GRAM = 3

  # pool: transactions with their entries loaded. common_share: a feature in
  # more than this share of the pool ("card", " pa") says nothing about which
  # transaction it is, and its postings are the long ones, so it's ignored.
  def initialize(pool, threshold:, min_neighbours:, common_share:)
    @pool = pool
    @threshold = threshold
    @min_neighbours = min_neighbours
    @common_share = common_share
  end

  # [[pool transaction, similarity]] at or above the threshold, best first;
  # never the transaction itself.
  def neighbours(transaction)
    query = vectors_for(transaction.entry.name)
    sums = Hash.new(0.0)
    query.each do |kind, vector|
      vector.each do |feature, weight|
        index[kind][feature]&.each { |i, pool_weight| sums[i] += weight * pool_weight / 2 }
      end
    end
    sums.filter_map { |i, similarity| [ pool[i], similarity ] if similarity >= threshold && pool[i].id != transaction.id }
        .sort_by { |_, similarity| -similarity }
  end

  # The value of attribute the neighbours agree on: at least min_neighbours
  # of them have one, and all that have one have the same. Neighbours
  # without one (nil) don't count either way.
  def agreed(transaction, attribute)
    self.class.agreed(neighbours(transaction).filter_map { |neighbour, _| neighbour.public_send(attribute) }, min_neighbours)
  end

  # The value when at least min_neighbours values are given, all the same.
  def self.agreed(values, min_neighbours)
    values.first if values.size >= min_neighbours && values.uniq.one?
  end

  private
    attr_reader :pool, :threshold, :min_neighbours, :common_share

    # { words: { feature => [[pool index, weight]] }, grams: ... }
    def index
      @index ||= begin
        index = { words: {}, grams: {} }
        pool_vectors.each_with_index do |vectors, i|
          vectors.each { |kind, vector| vector.each { |feature, weight| (index[kind][feature] ||= []) << [ i, weight ] } }
        end
        index
      end
    end

    def pool_vectors
      @pool_vectors ||= pool_features.map { |features| weigh(features) }
    end

    def pool_features
      @pool_features ||= pool.map { |transaction| features(transaction.entry.name) }
    end

    # { words: { feature => weight }, grams: ... }, each L2-normalized, with
    # sublinear tf × idf; features unknown to the pool or too common skipped.
    def vectors_for(text)
      weigh(features(text))
    end

    def weigh(features)
      features.to_h do |kind, counts|
        weights = counts.filter_map do |feature, count|
          idf = idfs[kind][feature]
          [ feature, (1 + Math.log(count)) * idf ] if idf
        end.to_h
        norm = Math.sqrt(weights.values.sum { |weight| weight**2 })
        [ kind, norm.zero? ? {} : weights.transform_values { |weight| weight / norm } ]
      end
    end

    def idfs
      @idfs ||= begin
        max_documents = [ (pool.size * common_share).floor, MIN_DOCUMENT_CAP ].max
        %i[words grams].to_h do |kind|
          documents = pool_features.each_with_object(Hash.new(0)) { |features, df| features[kind].each_key { |feature| df[feature] += 1 } }
          idf = documents.filter_map do |feature, df|
            [ feature, Math.log((pool.size + 1.0) / (df + 1)) + 1 ] if df <= max_documents
          end.to_h
          [ kind, idf ]
        end
      end
    end

    # { words: { word => count }, grams: { 3-gram => count } }
    def features(text)
      words = text.to_s.downcase.scan(/[\p{L}\p{N}]+/)
                  .select { |word| word.match?(/\p{L}/) && !word.match?(Family::BayesCategorizer::CODE) }
      padded = " #{words.join(" ")} "
      grams = padded.length < GRAM ? [] : (0..padded.length - GRAM).map { |i| padded[i, GRAM] }
      { words: words.tally, grams: grams.tally }
    end
end
