require 'forwardable'
require 'dr/base/utils'
require 'shell_helpers'
require 'dr/ruby_ext/core_ext'

module Archlinux
	ArchlinuxError=Class.new(StandardError)
	Utils=::DR::Utils
	Pathname=::SH::Pathname

	def self.delegate_h(klass, var)
		klass.extend(Forwardable)
		methods=[:[], :[]=, :any?, :assoc, :clear, :compact, :compact!, :delete, :delete_if, :dig, :each, :each_key, :each_pair, :each_value, :empty?, :fetch, :fetch_values, :has_key?, :has_value?, :include?, :index, :invert, :keep_if, :key, :key?, :keys, :length, :member?, :merge, :merge!, :rassoc, :reject, :reject!, :select, :select!, :shift, :size, :slice, :store, :to_a, :to_h, :to_s, :transform_keys, :transform_keys!, :transform_values, :transform_values!, :update, :value?, :values, :values_at]
		klass.include(Enumerable)
		klass.send(:def_delegators, var, *methods)
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

	def self.create_class(klass, *parameters, &b)
		klass=Archlinux.const_get(klass) if klass.is_a?(Symbol)
		if klass.is_a?(Proc)
			klass.call(*parameters, &b)
		else
			klass.new(*parameters, &b)
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
