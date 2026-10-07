# frozen_string_literal: true

require "spec_helper"
require "addressable/uri"

describe Addressable::URI, "solve_base" do
  def resolves?(base, pairs)
    parsed_base = Addressable::URI.parse(base)
    pairs.all? do |reference, target|
      parsed_base.join(Addressable::URI.parse(reference)).to_s == target
    end
  end

  def verify_solution(solution, pairs)
    expect(solution).to_not be_no_solution
    expect(resolves?(solution.base.to_s, pairs)).to eq(true)
  end

  it "is also available under reverse_resolve and constraint_solve" do
    pairs = [["a", "http://h/a"]]
    expect(described_class.reverse_resolve(pairs).status).to eq(:family)
    expect(described_class.constraint_solve(pairs).status).to eq(:family)
  end

  it "accepts a hash of reference/target constraints" do
    solution = described_class.solve_base(
      "a" => "http://h/a", "b" => "http://h/b"
    )
    expect(solution).to be_family
    expect(solution.base.to_s).to eq("http://h/")
  end

  it "accepts URI objects as constraints" do
    solution = described_class.solve_base(
      [[Addressable::URI.parse("a"), Addressable::URI.parse("http://h/a")]]
    )
    expect(solution).to be_family
    expect(solution.base.host).to eq("h")
  end

  it "raises when no constraints are supplied" do
    expect { described_class.solve_base([]) }.to raise_error(ArgumentError)
    expect { described_class.solve_base({}) }.to raise_error(ArgumentError)
  end

  it "raises TypeError for malformed pairs" do
    expect { described_class.solve_base([["a"]]) }.to raise_error(TypeError)
  end

  context "unique solutions" do
    it "pins every component when the empty reference is used" do
      pairs = [["", "http://user:pw@example.com:8080/a/b?q=1#f"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_unique
      expect(solution.free).to eq([])
      expect(solution.base.to_s).to eq(
        "http://user:pw@example.com:8080/a/b?q=1#f"
      )
    end

    it "pins the base when fragment and query are inherited as well" do
      pairs = [
        ["", "http://h/a/b?q=1#f"],
        ["#g", "http://h/a/b?q=1#g"]
      ]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_unique
      expect(solution.base.to_s).to eq("http://h/a/b?q=1#f")
    end
  end

  context "solution families" do
    it "does not use longest-common-prefix guessing for sibling paths" do
      pairs = {
        "a/b" => "http://example.com/x/a/b",
        "a/c" => "http://example.com/x/a/c"
      }
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.to_s).to eq("http://example.com/x/")
      expect(solution.free).to include(:path, :query, :fragment)
      verify_solution(solution, pairs.to_a)
    end

    it "treats fragment-only references as real constraints" do
      pairs = [["#section", "http://h/a/b#section"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.path).to eq("/a/b")
      expect(solution.base.query).to be_nil
      expect(solution.free).to eq([:fragment])
      verify_solution(solution, pairs)
    end

    it "treats query-only references as real constraints" do
      pairs = [["?x=1", "http://h/a/b?x=1"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.path).to eq("/a/b")
      expect(solution.free).to match_array([:query, :fragment])
      verify_solution(solution, pairs)
    end

    it "pins the base query to nil when a query ref meets a frag ref" do
      pairs = [
        ["?x=1", "http://h/p?x=1"],
        ["#f", "http://h/p#f"]
      ]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.to_s).to eq("http://h/p")
      expect(solution.free).to eq([:fragment])
      verify_solution(solution, pairs)
    end

    it "keeps the base query free when a fragment target carries a query" do
      pairs = [
        ["?x=1", "http://h/p?x=1"],
        ["#f", "http://h/p?y=2#f"]
      ]
      solution = described_class.solve_base(pairs)
      # The fragment reference inherits base query y=2; the query-only
      # reference ignores the base query entirely.
      expect(solution).to be_family
      expect(solution.base.query).to eq("y=2")
      expect(solution.free).to eq([:fragment])
      verify_solution(solution, pairs)
    end

    it "resolves parent-directory references in reverse" do
      pairs = {
        "../e" => "http://h/a/e",
        "d" => "http://h/a/b/d"
      }
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.to_s).to eq("http://h/a/b/")
      verify_solution(solution, pairs.to_a)
    end

    it "represents the root directory for references escaping the root" do
      pairs = [["../../e", "http://h/e"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.path).to eq("/")
      verify_solution(solution, pairs)
    end

    it "handles dot segments in the reference" do
      pairs = [["d/../e", "http://h/a/b/e"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.path).to eq("/a/b/")
      verify_solution(solution, pairs)
    end

    it "handles references that merely self-reference a directory" do
      pairs = [[".", "http://h/a/b/"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.path).to eq("/a/b/")
      verify_solution(solution, pairs)
    end

    it "leaves every base component free for absolute references" do
      pairs = [["https://other/x", "https://other/x"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.free).to include(
        :scheme, :host, :path, :query, :fragment
      )
      verify_solution(solution, pairs)
    end

    it "uses only the scheme as a hint for network-path references" do
      pairs = [["//other/x", "http://other/x"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.free).to include(:host, :path, :query, :fragment)
      expect(solution.free).to_not include(:scheme)
      verify_solution(solution, pairs)
    end

    it "works with authority-less bases" do
      pairs = [["../c", "a/c"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      expect(solution.base.scheme).to be_nil
      expect(solution.base.host).to be_nil
      verify_solution(solution, pairs)
    end

    it "works with absolute-path references" do
      pairs = [["/x/y", "http://h/x/y"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      verify_solution(solution, pairs)
    end

    it "verifies every returned candidate with the real resolver" do
      pairs = {
        "a/b/../c" => "http://h/x/a/c",
        "a/d" => "http://h/x/a/d"
      }
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      pairs.each do |reference, target|
        expect(solution.base.join(reference).to_s).to eq(target)
      end
    end
  end

  context "no solution" do
    it "reports conflicting directory constraints" do
      pairs = {
        "a/b" => "http://h/x/a/b",
        "c/d" => "http://h/y/c/d"
      }
      solution = described_class.solve_base(pairs)
      expect(solution).to be_no_solution
      expect(solution.base).to be_nil
      expect(solution.conflict.size).to eq(2)
      expect(solution.conflict.map { |entry| entry[:reference] }).to(
        match_array(["a/b", "c/d"])
      )
    end

    it "reports conflicting hosts" do
      pairs = {
        "a" => "http://h1/a",
        "b" => "http://h2/b"
      }
      solution = described_class.solve_base(pairs)
      expect(solution).to be_no_solution
      expect(solution.conflict.size).to eq(2)
    end

    it "does not mistake independent fragment references for a conflict" do
      pairs = {
        "#a" => "http://h/p#a",
        "#b" => "http://h/p#b"
      }
      solution = described_class.solve_base(pairs)
      expect(solution).to be_family
      verify_solution(solution, pairs.to_a)
    end

    it "reports a singleton conflict for an impossible self-reference" do
      pairs = [["https://a/x", "https://b/x"]]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_no_solution
      expect(solution.conflict.size).to eq(1)
    end

    it "finds a minimal irreducible conflict subset" do
      pairs = [
        ["a", "http://h/a"],
        ["b", "http://h1/b"],
        ["c", "http://h2/c"]
      ]
      solution = described_class.solve_base(pairs)
      expect(solution).to be_no_solution
      expect(solution.conflict.size).to eq(2)
      expect(
        solution.conflict.map { |entry| entry[:target] }
      ).to match_array(["http://h1/b", "http://h2/c"])
    end
  end

  context "result object" do
    it "supports predicate methods and to_h" do
      solution = described_class.solve_base([["a", "http://h/a"]])
      expect(solution.status).to eq(:family)
      expect(solution.family?).to eq(true)
      expect(solution.unique?).to eq(false)
      expect(solution.to_h.keys).to match_array(
        [:status, :base, :free, :conflict]
      )
    end
  end
end
