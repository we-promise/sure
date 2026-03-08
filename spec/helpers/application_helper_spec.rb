require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#trend_text_class" do
    def make_trend(current:, previous:, favorable_direction: "up")
      Trend.new(current: current, previous: previous, favorable_direction: favorable_direction)
    end

    context "when trend is nil" do
      it "returns text-secondary" do
        expect(helper.trend_text_class(nil)).to eq("text-secondary")
      end
    end

    context "when direction is flat (current == previous)" do
      it "returns text-secondary" do
        trend = make_trend(current: 100, previous: 100)
        expect(helper.trend_text_class(trend)).to eq("text-secondary")
      end
    end

    context "when direction is up and favorable_direction is up (normal gain)" do
      it "returns text-success" do
        trend = make_trend(current: 110, previous: 100, favorable_direction: "up")
        expect(helper.trend_text_class(trend)).to eq("text-success")
      end
    end

    context "when direction is up and favorable_direction is down (e.g. debt decreasing is good)" do
      it "returns text-destructive" do
        trend = make_trend(current: 110, previous: 100, favorable_direction: "down")
        expect(helper.trend_text_class(trend)).to eq("text-destructive")
      end
    end

    context "when direction is down and favorable_direction is up (normal loss)" do
      it "returns text-destructive" do
        trend = make_trend(current: 90, previous: 100, favorable_direction: "up")
        expect(helper.trend_text_class(trend)).to eq("text-destructive")
      end
    end

    context "when direction is down and favorable_direction is down (e.g. debt paid off)" do
      it "returns text-success" do
        trend = make_trend(current: 90, previous: 100, favorable_direction: "down")
        expect(helper.trend_text_class(trend)).to eq("text-success")
      end
    end
  end
end
