# frozen_string_literal: true

module Addressable
  class URI
    ##
    # The result of a reverse resolution performed by
    # {Addressable::URI.solve_base}.
    #
    # A solution has one of three statuses:
    #
    # <code>:unique</code>::
    #   Exactly one base URI satisfies every constraint.
    # <code>:family</code>::
    #   A whole family of base URIs satisfies the constraints. {#base} is
    #   one verified member of that family and {#free} lists the components
    #   that are not fully determined.
    # <code>:no_solution</code>::
    #   No base URI can satisfy the constraints. {#conflict} contains a
    #   minimal subset of the supplied pairs that already disagree.
    class BaseSolution
      # @return [Symbol] One of <code>:unique</code>, <code>:family</code>,
      #   or <code>:no_solution</code>.
      attr_reader :status

      # @return [Addressable::URI] A verified member of the solution set.
      #   <code>nil</code> when the status is <code>:no_solution</code>.
      attr_reader :base

      # @return [Array<Symbol>] Components that may vary inside the solution
      #   family (<code>:scheme</code>, <code>:user</code>,
      #   <code>:password</code>, <code>:host</code>, <code>:port</code>,
      #   <code>:path</code>, <code>:query</code>,
      #   <code>:fragment</code>).
      attr_reader :free

      # @return [Array<Hash>] A minimal subset of the supplied pairs that
      #   conflict with each other. Each hash contains the original
      #   <code>:reference</code> and <code>:target</code> objects.
      attr_reader :conflict

      EMPTY_ARR = [].freeze

      # @!visibility private
      def initialize(status, base = nil, free = EMPTY_ARR, conflict = nil)
        @status = status
        @base = base
        @free = free
        @conflict = conflict
      end

      # @return [Boolean] <code>true</code> if exactly one base URI works.
      def unique?
        @status == :unique
      end

      # @return [Boolean] <code>true</code> if a free family of base URIs
      #   satisfies the constraints.
      def family?
        @status == :family
      end

      # @return [Boolean] <code>true</code> if no base URI works.
      def no_solution?
        @status == :no_solution
      end

      # @return [Hash{Symbol => Object}]
      def to_h
        {
          :status => @status,
          :base => @base,
          :free => @free,
          :conflict => @conflict
        }
      end
    end

    Pair = Struct.new(:reference, :target, :ref, :dst, :kind)
    private_constant :Pair

    COMPONENT_NAMES = %i[
      scheme user password host port path query fragment
    ].freeze

    ##
    # Performs the inverse of {Addressable::URI#join} (RFC 3986 Section 5,
    # "relative resolution"). Given a collection of
    # <em>relative reference &rarr; resolved URI</em> pairs, it finds a base
    # URI that resolves every reference to its paired target.
    #
    # The search models the reference resolution algorithm directly; it does
    # not rely on longest common path prefixes. Fragment-only and
    # query-only references participate in the constraints just like any
    # other reference. Every candidate base is re-checked by parsing it and
    # running it through {Addressable::URI#join} for every pair before it is
    # accepted.
    #
    # @example Hash form
    #   solution = Addressable::URI.solve_base(
    #     {"a/b" => "http://example.com/x/a/b",
    #      "a/c" => "http://example.com/x/a/c"}
    #   )
    #   solution.status    #=> :family
    #   solution.base.to_s #=> "http://example.com/x/"
    #   solution.free      #=> [:path, :query, :fragment]
    #
    # @param [Array<Array(#to_str, #to_str)>, Hash{#to_str => #to_str}]
    #   pairs The reference/target constraints.
    #
    # @return [Addressable::URI::BaseSolution] The solution, solution family,
    #   or a description of the conflict.
    #
    # @raise [ArgumentError] if no constraints are supplied.
    # @raise [TypeError] if a pair cannot be converted to two strings.
    def self.solve_base(*args)
      pairs = BaseConstraintSolver.coerce_pairs(args)
      BaseConstraintSolver.new(pairs).solve
    end
    class << self
      alias_method :reverse_resolve, :solve_base
      alias_method :constraint_solve, :solve_base
    end

    # @!visibility private
    class BaseConstraintSolver
      PARENT_SEG = '..'
      SELF_SEG = '.'
      FREE_SEG = 'free'
      MARKER = :removed
      STATE_LIMIT = 200

      attr_reader :pairs

      def self.coerce_pairs(args)
        raw_pairs =
          if args.length == 1 && args.first.is_a?(Hash)
            args.first.to_a
          elsif args.length == 1 && args.first.is_a?(Array)
            args.first
          else
            args
          end
        if raw_pairs.nil? || raw_pairs.empty?
          raise ArgumentError,
            'At least one reference/target pair is required.'
        end
        raw_pairs.each_with_index.map do |pair, index|
          unless pair.respond_to?(:[]) &&
              pair[0].respond_to?(:to_str) && pair[1].respond_to?(:to_str)
            raise TypeError,
              "Pair ##{index} must contain a reference and a target."
          end
          [pair[0], pair[1]]
        end
      end

      def initialize(raw_pairs)
        @pairs = raw_pairs.map do |reference, target|
          ref = URI.parse(reference.to_str)
          dst = URI.parse(target.to_str)
          Pair.new(reference, target, ref, dst, classify(ref))
        end
        collect_constraints
      end

      def solve
        verified = find_verified

        if verified
          free = detect_free_components(verified)
          status = free.empty? ? :unique : :family
          return BaseSolution.new(status, verified, free)
        end

        BaseSolution.new(
          :no_solution, nil, BaseSolution::EMPTY_ARR, conflict_report
        )
      end

      def find_verified
        host_variants = [nil]
        host_variants << 'example.invalid' if @synthetic_authority
        host_variants.each do |host|
          @path_candidates.each do |path|
            base = build_base(path, host)
            candidate = verify_candidate(base)
            return candidate if candidate
          end
        end
        nil
      end

      private

      # RFC 3986 Section 5.2.2, expressed as a category.
      def classify(ref)
        if ref.scheme
          :scheme
        elsif ref.authority
          :authority
        else
          path = ref.path || EMPTY_STR
          if path.empty?
            :empty_path
          elsif path.start_with?(SLASH)
            :absolute_path
          else
            :relative_path
          end
        end
      end

      def collect_constraints
        @pins = {}
        @raw_path_pins = []
        @rel_path_pairs = []
        @authority_refs = 0
        @absolute_path_refs = 0

        @pairs.each do |pair|
          case pair.kind
          when :empty_path
            pin_authority(pair)
            # An empty path inherits the base path. The base query is
            # inherited by same-document references only (no query in the
            # reference); the base fragment is inherited when no fragment
            # is supplied.
            @raw_path_pins << pair.dst.path
            pin(:query, pair.dst.query) if pair.ref.query.nil?
            pin(:fragment, pair.dst.fragment) if pair.ref.fragment.nil?
          when :absolute_path, :relative_path
            pin_authority(pair)
            @absolute_path_refs += 1 if pair.kind == :absolute_path
            if pair.kind == :relative_path
              @rel_path_pairs << pair
            end
          when :authority
            pin(:scheme, pair.dst.scheme)
            @authority_refs += 1
          end
        end

        # Authority-bearing references do not pin the base authority, but a
        # representative base still needs one to be a usable URI.
        @synthetic_authority = @authority_refs > 0 && @pins[:host].nil?
        @path_candidates = path_candidates
      end

      # Scheme-bearing references always resolve to themselves, so they
      # never constrain the base; such a pair is simply checked as-is.
      def verify_pair(base, pair)
        resolved =
          if pair.kind == :scheme
            pair.ref
          else
            base.join(pair.ref)
          end
        COMPONENT_NAMES.all? do |component|
          resolved.public_send(component) == pair.dst.public_send(component)
        end
      rescue InvalidURIError, ArgumentError
        false
      end

      def pin_authority(pair)
        dst = pair.dst
        pin(:scheme, dst.scheme)
        pin(:user, dst.user)
        pin(:password, dst.password)
        pin(:host, dst.host)
        pin(:port, dst.port)
      end

      def pin(name, value)
        @pins[name] = value unless @pins.key?(name)
      end

      def path_candidates
        distinct = @raw_path_pins.map { |path| path || EMPTY_STR }.uniq
        return distinct unless distinct.empty?

        candidates = relative_path_candidates
        needs_root = @pins[:host] || @synthetic_authority ||
          @absolute_path_refs > 0
        if needs_root
          candidates << SLASH
        end
        candidates << nil
        candidates.uniq
      end

      # Every relative-path pair admits a (usually free) family of base
      # directories. Any member of the family is a legitimate global
      # candidate, so we try every pair's family, in a canonical order, and
      # keep the first one that the real resolver verifies for all pairs.
      def relative_path_candidates
        candidates = []
        @rel_path_pairs.each do |pair|
          family = directory_candidates(pair)
          candidates.concat(family)
          # Addressable's normalizer occasionally leaves ".." segments in
          # place (see its non-standard handling of relative overflow);
          # add bounded extra prefix depth and let verification decide.
          family.each do |directory|
            prefixed = directory
            3.times do
              prefixed = directory.start_with?(SLASH) ?
                FREE_SEG + prefixed :
                FREE_SEG + SLASH + prefixed
              candidates << prefixed
            end
          end
        end
        candidates.uniq.sort_by do |directory|
          [directory.count(SLASH),
           directory.scan(FREE_SEG).size,
           directory.include?(PARENT_SEG) ? 1 : 0]
        end
      end

      # Runs the remove-dot-segments loop of Section 5.2.4 backwards.
      # Stacks hold surviving output segment names plus temporary MARKER
      # entries for segments pushed by the reference and later popped by a
      # "..". MARKERs that survive to the beginning were directory segments
      # of the base itself; their names are free.
      def directory_candidates(pair)
        target_path = pair.dst.path || EMPTY_STR
        absolute = target_path.start_with?(SLASH)
        body = absolute ? target_path[1..-1] : target_path
        stack = body.empty? ? [] : body.split(SLASH, -1)
        stack.pop if stack.last == EMPTY_STR

        ref_path = pair.ref.path || EMPTY_STR
        segments = ref_path.split(SLASH, -1)
        segments.pop if ref_path.end_with?(SLASH)

        states = [stack]
        segments.reverse_each do |segment|
          next_states = []
          states.each do |state|
            case segment
            when SELF_SEG
              next_states << state
            when PARENT_SEG
              # RFC 5.2.4: ".." pops the last segment; at an empty stack it
              # is discarded. A surviving MARKER means the popped segment
              # was a free directory name from the base.
              next_states << state
              next_states << state + [MARKER] unless state.empty?
              # Addressable's normalizer also collapses a trailing
              # "<segment>/.." in one pass, which can leave the segment in
              # place; reverse that by dropping the last entry regardless
              # of its name.
              next_states << state[0...-1] unless state.empty?
            else
              # A segment may have been pushed and then removed by a later
              # "..", leaving no trace in the target stack.
              next_states << state
              if state.last == MARKER
                # This push was consumed by a later ".."; the popped name
                # is arbitrary and drops out of the state.
                next_states << state[0...-1]
              end
              if state.last == segment
                # The push survived into the target stack.
                next_states << state[0...-1]
              end
            end
          end
          states = next_states.uniq
          if states.size > STATE_LIMIT
            states = states.sort_by { |state| state.size }.first(STATE_LIMIT)
          end
        end

        states.each_with_object([]) do |state, result|
          state.map! { |entry| entry == MARKER ? FREE_SEG : entry }
          result << render_directory(absolute, state)
          while state.first == FREE_SEG
            state = state[1..-1]
            result << render_directory(absolute, state)
          end
        end.uniq
      end

      def render_directory(absolute, stack)
        if stack.empty?
          absolute ? SLASH : EMPTY_STR
        else
          prefix = absolute ? SLASH : EMPTY_STR
          "#{prefix}#{stack.join(SLASH)}#{SLASH}"
        end
      end

      def build_base(path, host_override = nil)
        host = @pins[:host] || host_override
        URI.new(
          :scheme => @pins[:scheme],
          :user => @pins[:user],
          :password => @pins[:password],
          :host => host,
          :port => @pins[:port],
          :path => path,
          :query => @pins[:query],
          :fragment => @pins[:fragment]
        )
      rescue InvalidURIError
        nil
      end

      # The authoritative check: run the real resolver and compare every
      # component with the declared target.
      def verify_candidate(base)
        return nil unless base
        base if @pairs.all? { |pair| verify_pair(base, pair) }
      end

      # Probes whether a component may vary while every constraint still
      # holds. This avoids guessing freedom from pin bookkeeping and trusts
      # the real resolver for the final classification.
      def detect_free_components(base)
        variations = {
          :scheme => ['gopher', 'http', nil],
          :user => ['probe-user', nil],
          :password => ['probe-password', nil],
          :host => ['probe.example', nil],
          :port => [9999, nil],
          :query => ['probe=1', nil],
          :fragment => ['probe', nil]
        }
        free = variations.keys.select do |component|
          variations[component].any? do |value|
            next false if value == base.public_send(component)
            candidate_for_probe(base, component, value) do |candidate|
              verify_candidate(candidate)
            end
          end
        end
        free << :path if path_is_free?(base)
        free
      end

      def mutate(base, component, value)
        candidate = base.dup
        candidate.public_send(component.to_s + '=', value)
        candidate
      rescue InvalidURIError, ArgumentError
        nil
      end

      def path_is_free?(base)
        original = base.path || EMPTY_STR
        variations = []
        if original.end_with?(SLASH)
          variations << original + 'probe'
        elsif original.empty?
          variations << 'probe'
          variations << SLASH
        else
          index = original.rindex(SLASH)
          directory = index ? original[0..index] : EMPTY_STR
          variations << directory + 'probe'
          variations << directory
        end
        variations.any? do |path|
          next false if path == original
          candidate_for_probe(base, :path, path) do |candidate|
            verify_candidate(candidate)
          end
        end
      end

      # Some component values only form valid URIs together (for example a
      # scheme needs an authority or an absolute path). Retry the mutation
      # with minimal complementary components when validation fails.
      def candidate_for_probe(base, component, value)
        candidate = mutate(base, component, value)
        return yield(candidate) if candidate

        augmented = base.dup
        begin
          augmented.defer_validation do
            augmented.public_send(component.to_s + '=', value)
            if component == :scheme
              augmented.host = 'probe.example' if augmented.host.nil?
              augmented.path = SLASH if (augmented.path || EMPTY_STR).empty?
            end
          end
        rescue InvalidURIError, ArgumentError
          return false
        end
        begin
          yield(augmented)
        rescue InvalidURIError, ArgumentError
          false
        end
      end

      # Finds a minimal unsatisfiable subset: drop a pair whenever the
      # remaining pairs are still unsatisfiable.
      def conflict_report
        remaining = @pairs.dup
        @pairs.each do |pair|
          candidate_set = remaining - [pair]
          if !candidate_set.empty? && !quick_feasible?(candidate_set)
            remaining = candidate_set
          end
        end
        remaining.map do |pair|
          {:reference => pair.reference, :target => pair.target}
        end
      end

      # Lightweight feasibility used while shrinking the conflict set; the
      # full solver is only needed for the externally visible result.
      def quick_feasible?(subset)
        solver = self.class.allocate
        solver.send(:initialize_from_pairs, subset)
        !!solver.find_verified
      end

      def initialize_from_pairs(pairs)
        @pairs = pairs
        collect_constraints
      end

      EMPTY_STR = ''.freeze
      private_constant :EMPTY_STR
    end
  end
end
