require 'forwardable'
require 'dr/base/utils'
require 'dr/base/uri' # for DR::URI.escape
require 'shell_helpers'
require 'dr/ruby_ext/core_ext'

module Archlinux
	ArchlinuxError=Class.new(StandardError)
	Utils=::DR::Utils
	Pathname=::SH::Pathname

	def self.delegate_h(klass, var)
		# put in a Module so that they are easier to distinguish from the
		# 'real' functions
		m=Module.new do
			extend(Forwardable)
			methods=[:[], :[]=, :any?, :assoc, :clear, :compact, :compact!, :delete, :delete_if, :dig, :each, :each_key, :each_pair, :each_value, :empty?, :fetch, :fetch_values, :has_key?, :has_value?, :include?, :index, :invert, :keep_if, :key, :key?, :keys, :length, :member?, :merge, :merge!, :rassoc, :reject, :reject!, :select, :select!, :shift, :size, :slice, :store, :to_a, :to_h, :to_s, :transform_keys, :transform_keys!, :transform_values, :transform_values!, :update, :value?, :values, :values_at]
			include(Enumerable)
			def_delegators var, *methods
		end
		klass.include(m)
	end

	def self.add_to_hash(h, key, value)
		case h[key]
		when nil
			h[key] = value
		when Array
			h[key] << value
		else
			h[key]=[h[key], value]
		end
	end

	def self.create_class(klass, *parameters, **kw, &b)
		klass=Archlinux.const_get(klass) if klass.is_a?(Symbol)
		if klass.is_a?(Proc)
			klass.call(*parameters, **kw, &b)
		else
			klass.new(*parameters, **kw, &b)
		end
	end

	module CreateHelper
		def create(v, config: Archlinux.config)
			v.is_a?(self) ? v : self.new(v, config: config)
		end
	end

	## Not used: we modify Config#pretty_print directly
	# module PPHelper
	# 	def pretty_print_instance_variables
	# 		instance_variables.reject {|n| n==:@config}.sort
	# 	end
	# end
end
