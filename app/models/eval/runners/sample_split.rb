# Deterministic train/test split over a dataset's samples.
#
# Exists because Family::BayesCategorizer is trained on a family's own
# categorized history rather than shipped pre-trained, so evaluating it means
# holding some samples back to train on. Every other provider then has to be
# evaluated on the *same* held-out samples, or the numbers are not comparable.
#
# Two rules shape the split:
#
#   1. Null-expected samples can never train. Bayes trains on
#      `where.not(category_id: nil)`, so a sample whose correct answer is "no
#      category" has nothing to contribute to the model. They all land in test.
#   2. The categorized remainder is stratified by difficulty, so training does
#      not accidentally absorb every easy sample and leave a test set that is
#      uniformly hard.
#
# Seeded, so a run is reproducible and a later provider leg lands on exactly the
# same test set as the Bayes leg it is being compared against.
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

  # Describes the split in the run output so a reader can reproduce it and see
  # what the test set is actually made of — a test set that is 23% null-expected
  # behaves differently from one that is 13%, and that shift is a consequence of
  # rule 1 above rather than a property of the dataset.
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
          ordered = group.sort_by(&:id).shuffle(random: Random.new(seed + difficulty.hash))
          take = (ordered.size * train_ratio).round
          train_set.concat(ordered.first(take))
          test_set.concat(ordered.drop(take))
        end

        [ train_set.sort_by(&:id), test_set.sort_by(&:id) ]
      end
    end
end
