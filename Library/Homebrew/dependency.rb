require 'dependable'

# A dependency on another Homebrew formula.
class Dependency
  include Dependable

  attr_reader :name, :tags, :env_proc, :option_name

  DEFAULT_ENV_PROC = proc {}

  def initialize(name, tags=[], env_proc=DEFAULT_ENV_PROC, option_name=name)
    @name = name
    @tags = tags
    @env_proc = env_proc
    @option_name = option_name
  end

  def to_s
    name
  end

  def ==(other)
    instance_of?(other.class) && name == other.name
  end
  alias_method :eql?, :==

  def hash
    name.hash
  end

  def to_formula
    f = Formulary.factory(name)
    # Add this dependency's options to the formula's build args
    f.build.args = f.build.args.concat(options)
    f
  end

  def installed?
    to_formula.installed?
  end

  def satisfied?(inherited_options)
    installed? && missing_options(inherited_options).empty?
  end

  def missing_options(inherited_options=[])
    missing = options | inherited_options
    missing -= Tab.for_formula(to_formula).used_options
    missing -= to_formula.build.implicit_options
    missing
  end

  def modify_build_environment
    env_proc.call unless env_proc.nil?
  end

  def inspect
    "#<#{self.class.name}: #{name.inspect} #{tags.inspect}>"
  end

  # Define marshaling semantics because we cannot serialize @env_proc
  def _dump(*)
    Marshal.dump([name, tags])
  end

  def self._load(marshaled)
    new(*Marshal.load(marshaled))
  end

  class << self
    # Expand the dependencies of dependent recursively, optionally yielding
    # [dependent, dep] pairs to allow callers to apply arbitrary filters to
    # the list.
    # The default filter, which is applied when a block is not given, omits
    # optionals and recommendeds based on what the dependent has asked for.
    def expand(dependent, deps=dependent.deps, &block)
      expanded_deps = []

      deps.each do |dep|
        # FIXME don't hide cyclic dependencies
        next if dependent.name == dep.name

        case action(dependent, dep, &block)
        when :prune
          next
        when :skip
          expanded_deps.concat(expand(dep.to_formula, &block))
        when :keep_but_prune_recursive_deps
          expanded_deps << dep
        else
          expanded_deps.concat(expand(dep.to_formula, &block))
          expanded_deps << dep
        end
      end

      merge_repeats(expanded_deps)
    end

    def action(dependent, dep, &block)
      catch(:action) do
        if block_given?
          yield dependent, dep
        elsif dep.optional? || dep.recommended?
          prune unless dependent.build.with?(dep)
        end
      end
    end

    # Prune a dependency and its dependencies recursively
    def prune
      throw(:action, :prune)
    end

    # Prune a single dependency but do not prune its dependencies
    def skip
      throw(:action, :skip)
    end

    # Keep a dependency, but prune its dependencies
    def keep_but_prune_recursive_deps
      throw(:action, :keep_but_prune_recursive_deps)
    end

    def merge_repeats(deps)
      grouped = deps.group_by(&:name)

      deps.uniq.map do |dep|
        tags = grouped.fetch(dep.name).map(&:tags).flatten.uniq
        dep.class.new(dep.name, tags, dep.env_proc)
      end
    end
  end
end

class TapDependency < Dependency
  def initialize(name, tags=[], env_proc=DEFAULT_ENV_PROC, option_name=name)
    super(name, tags, env_proc, name.split("/").last)
  end

  def installed?
    super
  rescue FormulaUnavailableError
    false
  end
end
