# frozen_string_literal: true

#--
# Copyright (C) Bob Aman
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#++

require "addressable/uri"

module Addressable
  class URI
    ##
    # The result of a reverse base-URI constraint solve, as computed by
    # Addressable::URI.solve_base.
    #
    # A solution has one of three statuses:
    #
    # [:unique]
    #   Exactly one base URI satisfies every constraint (modulo the
    #   base's fragment, which never participates in resolution).
    # [:family]
    #   A whole family of base URIs satisfies every constraint. The
    #   unconstrained parts are reported through #free_components and
    #   #path_free_segments, and #base holds one concrete, verified
    #   representative of the family.
    # [:unsatisfiable]
    #   No base URI satisfies every constraint. #conflicts holds a
    #   minimal subset of the constraints that already cannot be
    #   satisfied simultaneously.
    class BaseSolution
      UNIQUE = :unique
      FAMILY = :family
      UNSATISFIABLE = :unsatisfiable

      # @return [Array<Array(Addressable::URI, Addressable::URI)>] The
      #   [reference, target] pairs the solution was computed from, in
      #   input order.
      attr_reader :constraints

      # @return [Symbol] One of :unique, :family or :unsatisfiable.
      attr_reader :status

      # @return [Addressable::URI, nil] A concrete base URI satisfying
      #   every constraint, or nil when unsatisfiable. For a family,
      #   this is one verified representative; components listed in
      #   #free_components may be changed freely.
      attr_reader :base

      # @return [Array<Symbol>] Components of the base URI that remain
      #   completely unconstrained, drawn from :scheme, :user,
      #   :password, :host, :port, :path and :query. The base's
      #   fragment is not listed: it never influences resolution and
      #   is always left unset.
      attr_reader :free_components

      # @return [Integer, nil] When the base path is only partially
      #   determined, the number of trailing path segments (the free
      #   directory segments consumed by ".." segments of a
      #   reference, plus the final segment) that may be chosen
      #   freely. nil when the path is either fully determined or
      #   fully free.
      attr_reader :path_free_segments

      # @return [Array<Array(Addressable::URI, Addressable::URI)>] For
      #   an unsatisfiable solution, a minimal subset of the
      #   constraints that is already unsatisfiable on its own. Empty
      #   otherwise.
      attr_reader :conflicts

      def initialize(values={})
        @constraints = values[:constraints] || []
        @status = values[:status]
        @base = values[:base]
        @free_components = values[:free_components] || []
        @path_free_segments = values[:path_free_segments]
        @conflicts = values[:conflicts] || []
      end

      # @return [TrueClass, FalseClass] True when exactly one base URI
      #   satisfies every constraint.
      def unique?
        @status == UNIQUE
      end

      # @return [TrueClass, FalseClass] True when a family of base
      #   URIs satisfies every constraint.
      def family?
        @status == FAMILY
      end

      # @return [TrueClass, FalseClass] True when no base URI
      #   satisfies every constraint.
      def unsatisfiable?
        @status == UNSATISFIABLE
      end

      ##
      # Re-verifies the candidate base URI against every constraint by
      # resolving each reference with Addressable::URI#join and
      # comparing the result, component by component, with the known
      # target URI.
      #
      # @return [TrueClass, FalseClass] True when the candidate base
      #   resolves every reference to its known target.
      def valid?
        return false if unsatisfiable?
        @constraints.all? do |reference, target|
          URI.resolution_matches?(@base, reference, target)
        end
      end
    end

    # Components compared when verifying a resolved URI against its
    # known target.
    RESOLUTION_COMPONENTS =
      [:scheme, :user, :password, :host, :port, :path, :query,
        :fragment].freeze

    # Components of a base URI that resolution may copy into the
    # result.
    SCALAR_COMPONENTS =
      [:scheme, :user, :password, :host, :port, :query].freeze

    # Components that may be reported as fully unconstrained.
    FREEABLE_COMPONENTS =
      [:scheme, :user, :password, :host, :port, :path, :query].freeze

    # Segment used to fill unconstrained directory segments of a
    # representative base path. Any normal segment would do: these
    # segments are always consumed by ".." segments of the
    # reference during resolution.
    FAMILY_FILL_SEGMENT = "x"

    # Host used when a representative base would otherwise be invalid
    # without one (the host is unconstrained in that case, so any
    # value is a valid member of the solution family).
    FAMILY_FILL_HOST = "example.invalid"

    ##
    # Solves for a base URI from a set of reverse constraints: pairs
    # of a relative reference and the absolute URI it is known to
    # resolve to. The base is computed by inverting the reference
    # resolution semantics of RFC 3986 section 5.2 (the same
    # semantics implemented by Addressable::URI#join), not by
    # guessing a longest common prefix of the targets. References
    # consisting of only a fragment or only a query participate as
    # constraints like any other.
    #
    # The returned Addressable::URI::BaseSolution reports whether
    # the constraints determine a unique base URI, a family of base
    # URIs with free parts, or no base URI at all (in which case a
    # minimal conflicting subset of the pairs is identified). Every
    # candidate base URI is verified by resolving each reference
    # with the existing parser before it is returned.
    #
    # @param [Hash, Array] constraints Pairs of [reference, target],
    #   either as a Hash mapping reference URIs to their known
    #   absolute targets, or as an Array of two-element Arrays.
    #   Values may be Strings or Addressable::URI objects.
    #
    # @return [Addressable::URI::BaseSolution] The solution.
    #
    # @example A unique base
    #   Addressable::URI.solve_base([
    #     ["page.html", "http://example.com/dir/page.html"],
    #     ["#top", "http://example.com/dir/index.html#top"]
    #   ]).base.to_s
    #   #=> "http://example.com/dir/index.html"
    #
    # @example A family of bases
    #   solution = Addressable::URI.solve_base([
    #     ["../img/logo.png", "http://example.com/assets/img/logo.png"]
    #   ])
    #   solution.status             #=> :family
    #   solution.base.to_s          #=> "http://example.com/assets/x/"
    #   solution.path_free_segments #=> 2
    #
    # @example Conflicting constraints
    #   solution = Addressable::URI.solve_base([
    #     ["c/d", "http://example.com/a/c/d"],
    #     ["e", "http://example.com/a/x/e"]
    #   ])
    #   solution.status           #=> :unsatisfiable
    #   solution.conflicts.length #=> 2
    def self.solve_base(constraints)
      pairs = constraint_pairs(constraints)
      solved = solve_constraint_pairs(pairs)
      if solved.nil?
        return BaseSolution.new(
          :status => BaseSolution::UNSATISFIABLE,
          :constraints => pairs,
          :conflicts => minimal_conflicting_pairs(pairs)
        )
      end
      BaseSolution.new(
        :status => solved[:status],
        :constraints => pairs,
        :base => solved[:base],
        :free_components => solved[:free_components],
        :path_free_segments => solved[:path_free_segments]
      )
    end

    ##
    # Checks whether resolving +reference+ against +base+ yields
    # +target+, comparing every URI component.
    #
    # @param [Addressable::URI] base The candidate base URI.
    # @param [Addressable::URI] reference The reference to resolve.
    # @param [Addressable::URI] target The expected resolution
    #   result.
    #
    # @return [TrueClass, FalseClass] True when the resolution
    #   matches.
    def self.resolution_matches?(base, reference, target)
      resolved = base.join(reference)
      RESOLUTION_COMPONENTS.all? do |component|
        resolved.send(component) == target.send(component)
      end
    end

    ##
    # Normalizes the constraint input into an Array of parsed
    # [reference, target] pairs.
    #
    # @api private
    def self.constraint_pairs(constraints)
      unless constraints.respond_to?(:to_ary) ||
          constraints.respond_to?(:to_hash)
        raise TypeError,
          "Can't convert #{constraints.class} into constraint pairs."
      end
      entries = constraints.respond_to?(:to_ary) ?
        constraints.to_ary : constraints.to_hash.to_a
      entries.map do |entry|
        reference, target = entry
        reference = URI.parse(reference)
        target = URI.parse(target)
        if reference.nil? || target.nil?
          raise TypeError, "Constraint pairs must not contain nil."
        end
        [reference, target]
      end
    end
    private_class_method :constraint_pairs

    ##
    # Combines the constraints of every pair. Returns nil when the
    # pairs cannot be satisfied simultaneously; otherwise a Hash
    # describing the solution.
    #
    # @api private
    def self.solve_constraint_pairs(pairs)
      scalars = {}
      exact_path = nil
      exact_set = false
      merges = []
      matchers = nil

      pairs.each do |reference, target|
        constraint = constraint_for_pair(reference, target)
        return nil if constraint.nil?

        constraint[:scalars].each do |component, value|
          if scalars.key?(component)
            return nil unless scalars[component] == value
          else
            scalars[component] = value
          end
        end

        unless constraint[:exact].nil?
          if exact_set
            return nil unless exact_path == constraint[:exact]
          else
            exact_path = constraint[:exact]
            exact_set = true
          end
        end

        unless constraint[:merge].nil?
          merges << constraint[:merge]
          matchers = matchers.nil? ?
            constraint[:merge][:matchers] :
            intersect_merge_constraints(
              matchers, constraint[:merge][:matchers])
          return nil if matchers.empty?
        end
      end

      authority = scalars[:host] != nil

      # An exact base path is checked against every merge constraint
      # by directly simulating the path merge of Addressable::URI#join.
      if exact_set &&
          !merge_resolutions_match?(exact_path, merges, authority)
        return nil
      end
      # A relative reference can only merge into a relative base
      # path, which a base with an authority component cannot have.
      if !exact_set && !matchers.nil? && authority &&
          matchers.none? { |matcher| matcher_absolute?(matcher) }
        return nil
      end

      path_free_segments = nil
      path_free = false
      if exact_set
        path_value = exact_path
      elsif !matchers.nil?
        matcher = matchers.first
        case matcher[0]
        when :overflow
          path_value =
            SLASH + (FAMILY_FILL_SEGMENT + SLASH) * matcher[1]
          path_free_segments = matcher[1] + 1
        when :relative_root
          path_value = EMPTY_STR
          path_free_segments = 1
        else
          path_value =
            matcher[1] + (FAMILY_FILL_SEGMENT + SLASH) * matcher[3]
          path_free_segments = matcher[3] + 1
        end
      else
        path_value = EMPTY_STR
        path_free = true
      end

      free_components = FREEABLE_COMPONENTS.reject do |component|
        if component == :path
          !path_free
        else
          scalars.key?(component)
        end
      end

      status = free_components.empty? && path_free_segments.nil? ?
        BaseSolution::UNIQUE : BaseSolution::FAMILY
      base = build_representative(scalars, path_value, free_components)

      # The candidate is verified against every constraint with the
      # existing resolver before it is returned. Constraints that
      # would require a relative base path exercise normalization
      # behavior the solver deliberately does not model; those
      # candidates are rejected here rather than returned unverified.
      return nil unless pairs.all? do |reference, target|
       resolution_matches?(base, reference, target)
      end

      {
        :status => status,
        :base => base,
        :free_components => free_components,
        :path_free_segments => path_free_segments
      }
    end
    private_class_method :solve_constraint_pairs

    ##
    # Extracts the constraints a single [reference, target] pair
    # imposes on the base URI, by inverting Addressable::URI#join.
    # Returns nil when the pair is self-contradictory (no base URI
    # could resolve the reference to the target).
    #
    # @api private
    def self.constraint_for_pair(reference, target)
      # The fragment of the resolved URI always comes from the
      # reference.
      return nil if reference.fragment != target.fragment

      scalars = {}
      exact = nil
      merge = nil

      if reference.scheme != nil
        # An absolute reference resolves independently of the base.
        return nil unless absolute_reference_matches?(reference, target)
      elsif reference.authority != nil
        # A network-path reference takes only the scheme from the
        # base.
        return nil unless target.user == reference.user &&
          target.password == reference.password &&
          target.host == reference.host &&
          target.port == reference.port &&
          target.path == URI.normalize_path(reference.path) &&
          target.query == reference.query
        scalars[:scheme] = target.scheme
      elsif reference.path.nil? || reference.path.empty?
        # An empty-path reference (including query-only and
        # fragment-only references) inherits path, and possibly
        # query, from the base.
        scalars[:scheme] = target.scheme
        scalars[:user] = target.user
        scalars[:password] = target.password
        scalars[:host] = target.host
        scalars[:port] = target.port
        exact = target.path
        if reference.query != nil
          return nil unless target.query == reference.query
        else
          scalars[:query] = target.query
        end
      elsif reference.path[0..0] == SLASH
        # An absolute-path reference constrains only scheme and
        # authority of the base.
        return nil unless
          target.path == URI.normalize_path(reference.path) &&
          target.query == reference.query
        scalars[:scheme] = target.scheme
        scalars[:user] = target.user
        scalars[:password] = target.password
        scalars[:host] = target.host
        scalars[:port] = target.port
      else
        # A relative-path reference is merged into the directory of
        # the base path.
        return nil unless target.query == reference.query
        scalars[:scheme] = target.scheme
        scalars[:user] = target.user
        scalars[:password] = target.password
        scalars[:host] = target.host
        scalars[:port] = target.port
        merge = invert_merge(reference.path, target.path)
        return nil if merge.nil?
      end

      { :scalars => scalars, :exact => exact, :merge => merge }
    end
    private_class_method :constraint_for_pair

    ##
    # Checks a target against the resolution of an absolute
    # reference, which does not depend on the base URI.
    #
    # @api private
    def self.absolute_reference_matches?(reference, target)
      target.scheme == reference.scheme &&
        target.user == reference.user &&
        target.password == reference.password &&
        target.host == reference.host &&
       target.port == reference.port &&
        target.path == URI.normalize_path(reference.path) &&
        target.query == reference.query
    end
    private_class_method :absolute_reference_matches?

    ##
    # Inverts the path merge of RFC 3986 section 5.2.3: finds the
    # directories D such that normalize_path(D + reference_path)
    # equals target_path. Restricted to normalized directories, the
    # principal solution is the family D = prefix + z1/ + ... + zu/,
    # where the u trailing segments are free (they are consumed by
    # ".." segments of the reference).
    #
    # Returns a Hash with the reference and target paths plus a list
    # of directory matchers describing the solution family, or nil
    # when no directory resolves to the target:
    #
    # [:main, prefix, prefix_segments, u]
    #   Normalized directories of the form prefix + z1/ + ... + zu/
    #   with exactly u free trailing segments.
    # [:overflow, max]
    #   When more ".." segments remain than the directory has
    #   segments, remove_dot_segments absorbs them at the root of an
    #   absolute path, so any absolute directory with at most max
    #   segments resolves to the same target.
    # [:relative_root]
    #   The empty directory: a base path without any slash, on a
    #   base without an authority, leaves the reference to be
    #   normalized on its own.
    #
    # @api private
    def self.invert_merge(reference_path, target_path)
      unmatched = 0
      kept = []
      segments = reference_path.split(SLASH, -1)
      segments.each do |segment|
        if segment == SELF_REF
          # Removed by dot-segment removal.
        elsif segment == PARENT
          if kept.empty?
            unmatched += 1
          else
            kept.pop
          end
        else
          kept.push(segment)
        end
      end
      last = segments.last
      if (last == SELF_REF || last == PARENT) && !kept.empty?
       # A trailing "." or ".." leaves a trailing slash behind.
        kept = kept + [EMPTY_STR]
      end
      if kept.empty?
        if target_path.empty? || target_path.end_with?(SLASH)
          prefix = target_path
        end
      else
        suffix = kept.join(SLASH)
        if target_path.end_with?(suffix)
          candidate =
            target_path[0...target_path.length - suffix.length]
          prefix = candidate if candidate.empty? ||
            candidate.end_with?(SLASH)
        end
      end
      matchers = []
      unless prefix.nil?
        main = [:main, prefix, directory_segments(prefix), unmatched]
        # Relative directories exercise normalization behavior that
        # differs from the RFC 3986 stack model, so the candidate
        # directory is verified by direct simulation in any case.
        if main_matcher_works?(main, reference_path, target_path)
          matchers << main
        end
        if unmatched > 0 && prefix == SLASH
          matchers << [:overflow, unmatched - 1]
        end
      end
      if URI.normalize_path(reference_path) == target_path
        matchers << [:relative_root]
      end
      return nil if matchers.empty?
      {
        :matchers => matchers,
        :reference_path => reference_path,
        :target_path => target_path
      }
    end
    private_class_method :invert_merge

    ##
    # Checks the canonical directory of a main matcher against a
    # [reference_path, target_path] pair by directly simulating the
    # path merge.
    #
    # @api private
    def self.main_matcher_works?(main, reference_path, target_path)
      directory =
        main[1] + (FAMILY_FILL_SEGMENT + SLASH) * main[3]
      URI.normalize_path(directory + reference_path) == target_path
    end
    private_class_method :main_matcher_works?

    ##
    # Splits a directory string into its segments, excluding the
    # root and the empty segment after the trailing slash.
    #
    # @api private
    def self.directory_segments(directory)
      return [] if directory.empty?
      segments = directory.split(SLASH, -1)
      segments.shift if segments.first == EMPTY_STR
      segments.pop if segments.last == EMPTY_STR
      segments
    end
    private_class_method :directory_segments

    ##
    # Intersects two merge constraints, each a list of directory
    # matchers, keeping every pairwise combination that is
    # satisfiable.
    #
    # @api private
    def self.intersect_merge_constraints(first, second)
      first.product(second).map do |one, other|
        intersect_matchers(one, other)
      end.compact
    end
    private_class_method :intersect_merge_constraints

    ##
    # Intersects two directory matchers. Returns the combined
    # matcher, or nil when the matchers are incompatible.
    #
    # @api private
    def self.intersect_matchers(first, second)
      if first[0] == :overflow && second[0] == :overflow
        return [:overflow, [first[1], second[1]].min]
      end
      if first[0] == :overflow
        return main_within_overflow?(second, first) ? second : nil
      end
      if second[0] == :overflow
        return main_within_overflow?(first, second) ? first : nil
      end
      if first[0] == :relative_root || second[0] == :relative_root
        return intersect_relative_root(first, second)
      end
      # Two main matchers: each requires the directory to be its
      # prefix followed by exactly u free segments, so the
      # directories must have the same length and compatible
      # prefixes.
      return nil unless
        first[1].start_with?(SLASH) == second[1].start_with?(SLASH)
      return nil unless
        first[2].length + first[3] == second[2].length + second[3]
      if first[2].length <= second[2].length
        return nil unless second[2][0, first[2].length] == first[2]
        second
      else
        return nil unless first[2][0, second[2].length] == second[2]
        first
      end
    end
    private_class_method :intersect_matchers

    ##
    # Checks whether the directories selected by a main matcher all
    # satisfy an overflow matcher.
    #
    # @api private
    def self.main_within_overflow?(main, overflow)
      main[1].start_with?(SLASH) &&
        main[2].length + main[3] <= overflow[1]
    end
    private_class_method :main_within_overflow?

    ##
    # Intersects a relative-root matcher (the empty directory) with
    # another matcher.
    #
    # @api private
    def self.intersect_relative_root(first, second)
      if first[0] == :relative_root && second[0] == :relative_root
        return [:relative_root]
      end
      other = first[0] == :relative_root ? second : first
      # The empty directory only satisfies a main matcher that has
      # neither a prefix nor free segments.
      if other[0] == :main && other[1].empty? && other[3] == 0
        return [:relative_root]
      end
      nil
    end
    private_class_method :intersect_relative_root

    ##
    # Checks whether a directory matcher selects absolute
    # directories.
    #
    # @api private
    def self.matcher_absolute?(matcher)
      matcher[0] == :overflow ||
        (matcher[0] == :main && matcher[1].start_with?(SLASH))
    end
    private_class_method :matcher_absolute?

    ##
    # Checks an exact base path (required by an empty-path
    # reference) against every merge constraint, by directly
    # simulating the directory computation and path merge of
    # Addressable::URI#join.
    #
    # @api private
    def self.merge_resolutions_match?(exact_path, merges, authority)
      normalized = URI.normalize_path(exact_path)
      if normalized.include?(SLASH)
        directory = normalized[0..normalized.rindex(SLASH)]
      else
        directory = EMPTY_STR
      end
      directory = SLASH if directory.empty? && authority
      merges.all? do |merge|
        URI.normalize_path(directory + merge[:reference_path]) ==
          merge[:target_path]
      end
    end
    private_class_method :merge_resolutions_match?

    ##
    # Builds a concrete, valid representative base URI from the
    # combined constraints. Unconstrained components are left unset,
    # except that a placeholder host is used when the URI would
    # otherwise be invalid (any host is a valid member of the
    # solution family in that case).
    #
    # @api private
    def self.build_representative(scalars, path_value, free_components)
      uri = new
      uri.defer_validation do
        uri.scheme = scalars[:scheme] if scalars.key?(:scheme)
        uri.user = scalars[:user] if scalars.key?(:user)
        uri.password = scalars[:password] if scalars.key?(:password)
        uri.host = scalars[:host] if scalars.key?(:host)
        uri.port = scalars[:port] if scalars.key?(:port)
        uri.path = path_value
        uri.query = scalars[:query] if scalars.key?(:query)
      end
      uri
    rescue InvalidURIError
      raise unless free_components.include?(:host)
      with_host = scalars.dup
      with_host[:host] = FAMILY_FILL_HOST
      build_representative(with_host, path_value,
        free_components - [:host])
    end
    private_class_method :build_representative

    ##
    # Reduces an unsatisfiable set of pairs to a minimal subset that
    # is still unsatisfiable, by greedily dropping every pair that
    # is not required to keep it unsatisfiable.
    #
    # @api private
    def self.minimal_conflicting_pairs(pairs)
      kept = (0...pairs.length).to_a
      kept.each do |index|
        trial = kept - [index]
        trial_pairs = trial.map { |i| pairs[i] }
        kept = trial if solve_constraint_pairs(trial_pairs).nil?
      end
      kept.map { |i| pairs[i] }
    end
    private_class_method :minimal_conflicting_pairs
  end
end
