require "interactor/context"
require "interactor/error"
require "interactor/hooks"
require "interactor/organizer"

# Public: Interactor methods. Because Interactor is a module, custom Interactor
# classes should include Interactor rather than inherit from it.
#
# Examples
#
#   class MyInteractor
#     include Interactor
#
#     def call
#       puts context.foo
#     end
#   end
module Interactor
  # Internal: Install Interactor's behavior in the given class.
  def self.included(base)
    base.class_eval do
      extend ClassMethods
      include Hooks

      # Public: Gets the Interactor::Context of the Interactor instance.
      attr_reader :context

      # Interal: Class attributes that hold expected inputs and outputs.
      class_attribute :inputs, default: {}
      class_attribute :outputs, default: {}
    end
  end

  # Internal: Interactor class methods.
  module ClassMethods
    # Public: Invoke an Interactor. This is the primary public API method to an
    # interactor.
    #
    # context - A Hash whose key/value pairs are used in initializing a new
    #           Interactor::Context object. An existing Interactor::Context may
    #           also be given. (default: {})
    #
    # Examples
    #
    #   MyInteractor.call(foo: "bar")
    #   # => #<Interactor::Context foo="bar">
    #
    #   MyInteractor.call
    #   # => #<Interactor::Context>
    #
    # Returns the resulting Interactor::Context after manipulation by the
    #   interactor.
    def call(context = {})
      new(context).tap(&:run).context
    end

    # Public: Invoke an Interactor. The "call!" method behaves identically to
    # the "call" method with one notable exception. If the context is failed
    # during invocation of the interactor, the Interactor::Failure is raised.
    #
    # context - A Hash whose key/value pairs are used in initializing a new
    #           Interactor::Context object. An existing Interactor::Context may
    #           also be given. (default: {})
    #
    # Examples
    #
    #   MyInteractor.call!(foo: "bar")
    #   # => #<Interactor::Context foo="bar">
    #
    #   MyInteractor.call!
    #   # => #<Interactor::Context>
    #
    #   MyInteractor.call!(foo: "baz")
    #   # => Interactor::Failure: #<Interactor::Context foo="baz">
    #
    # Returns the resulting Interactor::Context after manipulation by the
    #   interactor.
    # Raises Interactor::Failure if the context is failed.
    def call!(context = {})
      new(context).tap(&:run!).context
    end

    # Interal: Borrowed from ActiveSupport.
    # Declare a class-level attribute whose value is inheritable by subclasses.
    # Subclasses can change their own value and it will not impact parent class.
    #
    # name      - A symbol or string defining the name of the class attribute.
    # default   - Default value with which the class attribute is initialized.
    #
    # Examples
    #
    #   class Base
    #     class_attribute :setting
    #   end
    #
    #   class Subclass < Base
    #   end
    #
    #   Base.setting = true
    #   Subclass.setting            # => true
    #   Subclass.setting = false
    #   Subclass.setting            # => false
    #   Base.setting                # => true
    #
    # In the above case as long as Subclass does not assign a value to setting
    # by performing <tt>Subclass.setting = _something_</tt>, <tt>Subclass.setting</tt>
    # would read value assigned to parent class. Once Subclass assigns a value then
    # the value assigned by Subclass would be returned.
    #
    # This matches normal Ruby method inheritance: think of writing an attribute
    # on a subclass as overriding the reader method. However, you need to be aware
    # when using +class_attribute+ with mutable structures as +Array+ or +Hash+.
    # In such cases, you don't want to do changes in place. Instead use setters:
    #
    #   Base.setting = []
    #   Base.setting                # => []
    #   Subclass.setting            # => []
    #
    #   # Appending in child changes both parent and child because it is the same object:
    #   Subclass.setting << :foo
    #   Base.setting               # => [:foo]
    #   Subclass.setting           # => [:foo]
    #
    #   # Use setters to not propagate changes:
    #   Base.setting = []
    #   Subclass.setting += [:foo]
    #   Base.setting               # => []
    #   Subclass.setting           # => [:foo]
    def class_attribute(name, default: nil)
      singleton_class.instance_eval do
        undef_method(name) if method_defined?(name) || private_method_defined?(name)
      end
      define_singleton_method(name) { default }

      ivar = "@#{name}"

      singleton_class.instance_eval do
        m = "#{name}="
        undef_method(m) if method_defined?(m) || private_method_defined?(m)
      end
      define_singleton_method("#{name}=") do |value|
        singleton_class.class_eval do
          undef_method(name) if method_defined?(name) || private_method_defined?(name)
          define_method(name) { value }
        end

        if singleton_class?
          class_eval do
            undef_method(name) if method_defined?(name) || private_method_defined?(name)
            define_method(name) do
              if instance_variable_defined? ivar
                instance_variable_get ivar
              else
                singleton_class.send name
              end
            end
          end
        end
        value
      end
    end

    # Public: Declare an expected input for an Interactor.
    #
    # attribute_name    - Name of the argument to pass to the .call method.
    # type              - Optional. If present, the provided input's class is validated
    #                     to be of same class or subclass. A TypeError is raised in case
    #                     of mismatching types.
    # optional          - Optional, defaults to false. If false, validates that a kwarg named
    #                     `attribute_name` was explicitly passed. Raises `Interactor::MissingInput`.
    #                     If set to true, skips the validation.
    #
    # Examples
    #
    #   class DoSomething
    #     include Interactor
    #
    #     input :user, type: User
    #     input :avatar, type: Image, optional: true
    #   end
    def input(attribute_name, type: nil, optional: false)
      self.inputs = inputs.merge(
        attribute_name.to_sym => {
          type: type,
          optional: optional
        }
      )
    end

    # Public: Declare an expected output for an Interactor.
    #
    # attribute_name    - Name of the argument to pass to the .call method.
    # type              - Optional. If present, the provided output's class is validated
    #                     to be of same class or subclass. A TypeError is raised in case
    #                     of mismatching types.
    # optional          - Optional, defaults to false. If false, validates that a kwarg named
    #                     `attribute_name` was explicitly passed. Raises `Interactor::MissingInput`.
    #                     If set to true, skips the validation.
    #
    # Examples
    #
    #   class DoSomething
    #     include Interactor
    #
    #     output :user, type: User
    #   end
    def output(attribute_name, type: nil, optional: false)
      self.outputs = outputs.merge(
        attribute_name.to_sym => {
          type: type,
          optional: optional
        }
      )
    end
  end

  # Internal: Initialize an Interactor.
  #
  # context - A Hash whose key/value pairs are used in initializing the
  #           interactor's context. An existing Interactor::Context may also be
  #           given. (default: {})
  #
  # Examples
  #
  #   MyInteractor.new(foo: "bar")
  #   # => #<MyInteractor @context=#<Interactor::Context foo="bar">>
  #
  #   MyInteractor.new
  #   # => #<MyInteractor @context=#<Interactor::Context>>
  def initialize(context = {})
    @context = Context.build(context)
  end

  # Internal: Invoke an interactor instance along with all defined hooks. The
  # "run" method is used internally by the "call" class method. The following
  # are equivalent:
  #
  #   MyInteractor.call(foo: "bar")
  #   # => #<Interactor::Context foo="bar">
  #
  #   interactor = MyInteractor.new(foo: "bar")
  #   interactor.run
  #   interactor.context
  #   # => #<Interactor::Context foo="bar">
  #
  # After successful invocation of the interactor, the instance is tracked
  # within the context. If the context is failed or any error is raised, the
  # context is rolled back.
  #
  # Returns nothing.
  def run
    run!
  rescue Failure
  end

  # Internal: Invoke an Interactor instance along with all defined hooks. The
  # "run!" method is used internally by the "call!" class method. The following
  # are equivalent:
  #
  #   MyInteractor.call!(foo: "bar")
  #   # => #<Interactor::Context foo="bar">
  #
  #   interactor = MyInteractor.new(foo: "bar")
  #   interactor.run!
  #   interactor.context
  #   # => #<Interactor::Context foo="bar">
  #
  # After successful invocation of the interactor, the instance is tracked
  # within the context. If the context is failed or any error is raised, the
  # context is rolled back.
  #
  # The "run!" method behaves identically to the "run" method with one notable
  # exception. If the context is failed during invocation of the interactor,
  # the Interactor::Failure is raised.
  #
  # Returns nothing.
  # Raises Interactor::Failure if the context is failed.
  def run!
    with_hooks do
      validate!(:input)
      call
      validate!(:output)
      context.called!(self)
    end
  rescue
    context.rollback!
    raise
  end

  # Public: Invoke an Interactor instance without any hooks, tracking, or
  # rollback. It is expected that the "call" instance method is overwritten for
  # each interactor class.
  #
  # Returns nothing.
  def call
  end

  # Public: Reverse prior invocation of an Interactor instance. Any interactor
  # class that requires undoing upon downstream failure is expected to overwrite
  # the "rollback" instance method.
  #
  # Returns nothing.
  def rollback
  end

  # Internal: Validates expected inputs/outputs at runtime.
  def validate!(kind)
    self.class.send("#{kind}s").each_pair do |attribute_name, opts|
      if !context.key?(attribute_name) && !opts[:optional]
        raise "Missing#{kind.capitalize}".constantize.new(context), "Missing required #{kind}: #{attribute_name}"
      end

      if opts[:type] && !(context[attribute_name].class <= opts[:type])
        raise TypeError, "Expected #{attribute_name} to be of type #{opts[:type]}, got #{context[attribute_name].class}"
      end
    end
  end
end
