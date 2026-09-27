# Deterministic train/test split over a dataset's samples. Family::BayesCategorizer
# trains on a family's own history rather than shipping pre-trained, so every
# provider must be scored on the same held-out samples to stay comparable. The
# seed is what lets a later provider leg land on the Bayes leg's test set.
#
# Two rules shape it:
#
#   1. Null-expected samples always land in test. Bayes trains on
#      `where.not(category_id: nil)` and cannot learn from them.
#   2. The categorized remainder is stratified by difficulty, so training does
#      not absorb the easy samples and leave a uniformly hard test set.
class Eval::Runners::SampleSplit
  DEFAULT_SEED = 42
  DEFAULT_TRAIN_RATIO = 0.5

  ROLES = %w[train test].freeze

  def initialize(samples, seed: DEFAULT_SEED, train_ratio: DEFAULT_TRAIN_RATIO)
    @samples = samples.to_a
    @seed = seed.to_i
    @train_ratio = train_ratio.to_f
  end

  def for_role(role)
    case role.to_s
    when "train" then train
    when "test" then test
    else raise ArgumentError, "Unknown split role #{role.inspect}; expected one of #{ROLES.join(', ')}"
    end
  end

  def train
    @train ||= partition.first
  end

  def test
    @test ||= partition.last
  end

  # Recorded in the run output so a split can be reproduced. The null-expected
  # share matters when comparing runs: rule 1 moves it with the dataset's
  # categorized ratio, so two runs over the same dataset can still differ.
  def describe
    {
      "seed" => seed,
      "train_ratio" => train_ratio,
      "train_size" => train.size,
      "test_size" => test.size,
      "test_null_expected" => test.count { |sample| sample.expected_category_name.nil? },
      "by_difficulty" => {
        "train" => train.group_by(&:difficulty).transform_values(&:size),
        "test" => test.group_by(&:difficulty).transform_values(&:size)
      }
    }
  end

  private
    attr_reader :samples, :seed, :train_ratio

    def partition
      @partition ||= begin
        trainable, untrainable = samples.partition { |sample| sample.expected_category_name.present? }

        train_set = []
        test_set = untrainable

        trainable.group_by(&:difficulty).each do |difficulty, group|
          ordered = group.sort_by(&:id).shuffle(random: Random.new(seed + difficulty_offset(difficulty)))
          take = (ordered.size * train_ratio).round
          train_set.concat(ordered.first(take))
          test_set.concat(ordered.drop(take))
        end

        [ train_set.sort_by(&:id), test_set.sort_by(&:id) ]
      end
    end

    # Not String#hash, which Ruby seeds per process — the legs of a cascade run
    # are separate `rake evals:run` processes, so one seed gave two shuffles.
    # Eval::Reporters::CascadeReport compares only seed and train_ratio, so it
    # cannot catch a regression here.
    def difficulty_offset(difficulty)
      Digest::SHA256.hexdigest(difficulty.to_s)[0, 8].to_i(16)
    end
end
