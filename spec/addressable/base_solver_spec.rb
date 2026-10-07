# frozen_string_literal: true

require "spec_helper"

require "addressable/base_solver"

describe Addressable::URI, ".solve_base" do
  def solve(pairs)
    Addressable::URI.solve_base(pairs)
  end

  describe "input handling" do
    it "accepts a Hash of reference to target" do
      solution = solve("page.html" => "http://example.com/dir/page.html")
      expect(solution).to be_family
      expect(solution).to be_valid
    end

    it "accepts Addressable::URI objects" do
      solution = solve([[
        Addressable::URI.parse("page.html"),
        Addressable::URI.parse("http://example.com/dir/page.html")
      ]])
      expect(solution).to be_valid
    end

   it "raises a TypeError for garbage input" do
     expect { solve(42) }.to raise_error(TypeError)
   end
 end
  describe "unique solutions" do
    it "pins down a unique base from a relative and a fragment-only reference" do
      solution = solve([
        ["page.html", "http://example.com/dir/page.html"],
        ["#top", "http://example.com/dir/index.html#top"]
      ])
      expect(solution.status).to eq :unique
      expect(solution).to be_unique
      expect(solution.base.to_s).to eq "http://example.com/dir/index.html"
      expect(solution.free_components).to eq []
      expect(solution.path_free_segments).to be_nil
      expect(solution).to be_valid
    end

    it "resolves an empty reference to the base itself" do
      solution = solve([["", "http://example.com/exact/path?q=1"]])
      expect(solution).to be_unique
      expect(solution.base.to_s).to eq "http://example.com/exact/path?q=1"
      expect(solution).to be_valid
    end

    it "lets a fragment-only reference constrain path and query" do
      solution = solve([["#s", "http://example.com/doc?x=1#s"]])
      expect(solution).to be_unique
      expect(solution.base.to_s).to eq "http://example.com/doc?x=1"
      expect(solution).to be_valid
    end

    it "never sets a fragment on the base" do
      solution = solve([["a", "http://example.com/a"]])
      expect(solution.base.fragment).to be_nil
    end
  end

  describe "solution families" do
    it "leaves the final path segment free for a relative reference" do
      solution = solve([["page.html", "http://example.com/dir/page.html"]])
      expect(solution.status).to eq :family
      expect(solution.base.to_s).to eq "http://example.com/dir/"
      expect(solution.path_free_segments).to eq 1
      expect(solution.free_components).to eq [:query]
      expect(solution).to be_valid
    end

    it "leaves directory segments consumed by \"..\" free" do
      solution = solve([
        ["../img/logo.png", "http://example.com/assets/img/logo.png"]
      ])
      expect(solution.status).to eq :family
      expect(solution.base.to_s).to eq "http://example.com/assets/x/"
      expect(solution.path_free_segments).to eq 2
      expect(solution).to be_valid
    end

    it "allows the free parts of a family to vary" do
      solution = solve([["page.html", "http://example.com/dir/page.html"]])
      variant = solution.base.dup
      variant.path = "/dir/anything-else.html"
      reference, target = solution.constraints.first
      expect(
        Addressable::URI.resolution_matches?(variant, reference, target)
      ).to be true
    end

    it "constrains only the scheme for a network-path reference" do
      solution = solve([
        ["//cdn.example.com/a.js", "https://cdn.example.com/a.js"]
      ])
      expect(solution.status).to eq :family
      expect(solution.free_components).to include(
        :user, :password, :host, :port, :path, :query
      )
      expect(solution.base.scheme).to eq "https"
      expect(solution).to be_valid
    end

    it "constrains only scheme and authority for an absolute-path reference" do
      solution = solve([["/root/x", "http://example.com/root/x"]])
      expect(solution.status).to eq :family
      expect(solution.free_components).to include(:path, :query)
      expect(solution.base.to_s).to eq "http://example.com"
      expect(solution).to be_valid
    end

    it "treats a consistent absolute reference as no constraint" do
      solution = solve([
        ["https://other.example/x", "https://other.example/x"],
        ["a", "https://example.com/a"]
      ])
      expect(solution.status).to eq :family
      expect(solution.base.to_s).to eq "https://example.com/"
      expect(solution).to be_valid
    end

    it "keeps user, password and port from the target" do
      solution = solve([[
        "a", "http://user:pass@example.com:8080/x/a"
      ]])
      expect(solution.base.user).to eq "user"
      expect(solution.base.password).to eq "pass"
      expect(solution.base.port).to eq 8080
      expect(solution.base.to_s).to eq "http://user:pass@example.com:8080/x/"
      expect(solution).to be_valid
    end

    it "lets a query-only reference constrain the path but not the query" do
      solution = solve([["?page=2", "http://example.com/list?page=2"]])
      expect(solution.status).to eq :family
      expect(solution.base.to_s).to eq "http://example.com/list"
      expect(solution.free_components).to eq [:query]
      expect(solution).to be_valid
    end
  end

  describe "unsatisfiable constraints" do
    it "rejects directories a longest common prefix would accept" do
      solution = solve([
        ["c/d", "http://example.com/a/c/d"],
        ["e", "http://example.com/a/x/e"]
      ])
      expect(solution.status).to eq :unsatisfiable
      expect(solution).to be_unsatisfiable
      expect(solution.base).to be_nil
      expect(solution.conflicts.length).to eq 2
      expect(solution).not_to be_valid
    end

    it "detects a fragment mismatch" do
      solution = solve([["a#x", "http://example.com/a#y"]])
      expect(solution).to be_unsatisfiable
      expect(solution.conflicts.length).to eq 1
    end

    it "detects a query mismatch" do
      solution = solve([["a?q=1", "http://example.com/a?q=2"]])
      expect(solution).to be_unsatisfiable
      expect(solution.conflicts.length).to eq 1
    end

    it "detects a self-contradictory absolute reference" do
      solution = solve([["https://other.example/x", "https://other.example/y"]])
      expect(solution).to be_unsatisfiable
      expect(solution.conflicts.length).to eq 1
    end

    it "rejects a relative merge that needs a path below the root" do
      solution = solve([["..", "http://example.com"]])
      expect(solution).to be_unsatisfiable
    end

    it "reports a minimal conflicting subset" do
      pairs = [
        ["a", "http://example.com/d1/a"],
        ["b", "http://example.com/d2/b"],
        ["#f", "http://example.com/d1/page#f"]
      ]
      solution = solve(pairs)
      expect(solution).to be_unsatisfiable
      expect(solution.conflicts.length).to eq 2
      # The reported subset must itself be unsatisfiable.
      subset = Addressable::URI.solve_base(solution.conflicts)
      expect(subset).to be_unsatisfiable
    end
  end

 describe "verification" do
   it "resolves every reference to its target with the existing parser" do
     pairs = [
       ["page.html", "http://example.com/dir/page.html"],
       ["#top", "http://example.com/dir/index.html#top"],
       ["?q=1", "http://example.com/dir/index.html?q=1"],
       ["/root", "http://example.com/root"],
       ["//example.com/net", "http://example.com/net"]
     ]
     solution = solve(pairs)
     expect(solution).to be_valid
     pairs.each do |reference, target|
       expect(solution.base.join(reference)).to eq(
         Addressable::URI.parse(target)
       )
     end
   end
 end

  describe "edge cases" do
    it "solves the RFC 3986 section 5.4 examples in reverse" do
      solution = solve([
        ["g:h", "g:h"],
        ["g", "http://a/b/c/g"],
        ["./", "http://a/b/c/"],
        ["g/", "http://a/b/c/g/"],
        ["/g", "http://a/g"],
        ["//g", "http://g"],
        ["?y", "http://a/b/c/d;p?y"],
        ["g?y", "http://a/b/c/g?y"],
        ["#s", "http://a/b/c/d;p?q#s"],
        ["g#s", "http://a/b/c/g#s"],
        ["g?y#s", "http://a/b/c/g?y#s"],
        [";x", "http://a/b/c/;x"],
        ["g;x", "http://a/b/c/g;x"],
        ["", "http://a/b/c/d;p?q"],
        [".", "http://a/b/c/"],
        ["./.", "http://a/b/c/"],
        ["..", "http://a/b/"],
        ["../", "http://a/b/"],
        ["../g", "http://a/b/g"],
        ["../..", "http://a/"],
        ["../../", "http://a/"],
        ["../../g", "http://a/g"]
      ])
      expect(solution).to be_unique
      expect(solution.base.to_s).to eq "http://a/b/c/d;p?q"
      expect(solution).to be_valid
    end

    it "absorbs \"..\" segments above the root of an absolute path" do
      solution = solve([
        ["../b", "http://example.com/b"],
        ["", "http://example.com/b"]
      ])
      expect(solution).to be_unique
      expect(solution.base.to_s).to eq "http://example.com/b"
      expect(solution).to be_valid
    end

    it "supports relative base URIs" do
      solution = solve([["x", "x"], ["../b", "b"]])
      expect(solution).to be_family
      expect(solution.base.to_s).to eq ""
      expect(solution).to be_valid
    end

    it "keeps unremovable dot segments of relative targets" do
      solution = solve([["b/..", "b/.."]])
      expect(solution).to be_valid
    end
  end
end

