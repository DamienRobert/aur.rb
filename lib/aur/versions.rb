require 'aur/helpers'

module Archlinux
	class Version
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		include Comparable
		attr_reader :epoch, :version, :pkgrel
		def initialize(*v)
			if v.length==1
				@v=v.first
				parse(@v)
			elsif v.empty?
				@epoch=-1 #any version is better than empty version
				@version=Gem::Version.new(0)
				@pkgrel=nil
			else
				@v=v
				epoch, version, pkgrel=v
				@epoch=epoch || 0
				@real_epoch= epoch ? true : false
				@real_version=version
				@version=set_version(version)
				@pkgrel=pkgrel
			end
		end

		# Gem::Version is super pickly :-(
		def set_version(version)
			version=version.tr('+_','.')
			@version=Gem::Version.new(version) rescue Gem::Version.new("0.#{version}")
		end

		private def parse(v)
			if v.nil? or v.empty?
				@epoch=-1 #any version is better than empty version
				@version=Gem::Version.new(0)
				@pkgrel=nil
				return
			end
			epoch, rest = v.split(':', 2)
			if rest.nil?
				rest=epoch; epoch=0
				@real_epoch=false
			else
				@real_epoch=true
			end
			@epoch=epoch
			version, pkgrel=Utils.rsplit(rest, '-', 2)
			set_version(version)
			@real_version=version
			@pkgrel=pkgrel.to_i
		end
		
		def <=>(w)
			w=self.class.new(w.to_s)
			r= @epoch <=> w.epoch
			if r==0
				r= @version <=> w.version
				if r==0 and @pkgrel and w.pkgrel
					r= @pkgrel <=> w.pkgrel
				end
			end
			r
		end

		def to_s
			# @v.to_s
			r=""
			r << "#{@epoch}:" if @real_epoch
			r << "#{@real_version}"
			r << "-#{@pkgrel}" if @pkgrel
			r
		end

		# strip version information from a package name
		def self.strip(v)
			v.sub(/[><=]+[\w.\-+:]*$/,'')
		end
	end

	# ex: pacman>=2.0.0
	QueryError=Class.new(ArchlinuxError)
	class Query
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def self.strip(query)
			self.create(query).name
		end

		include Comparable
		attr_accessor :name, :op, :version, :op2, :version2
		def initialize(query)
			@query=query
			@name, @op, version, @op2, version2=parse(query)
			@version=Version.new(version)
			@version2=Version.new(version2)
		end

		def to_s
			@query
		end

		def max
			strict=false
			if @op=='<=' or @op=='='
				max=@version
			elsif @op=="<"
				max=@version; strict=true
			elsif @op2=="<="
				max=@version2
			elsif @op2=="<"
				max=@version2; strict=true
			end
			return max, strict #nil means Float::INFINITY, ie no restriction
		end

		def min
			strict=false
			if @op=='>=' or @op=='='
				min=@version
			elsif @op==">"
				min=@version; strict=true
			elsif @op2==">="
				min=@version2
			elsif @op2==">"
				min=@version2; strict=true
			end
			return min, strict
		end

		def <=>(other)
			other=self.class.create(other)
			min, strict=self.min
			omin, ostrict=other.min
			return 1 if min==omin and strict
			return -1 if min==omin and ostrict
			min <=> omin
		end

		# here we check if a package can satisfy a query
		# note that other can itself be a query, think of a package that
		# requires foo>=2.0 and bar which provides foo>=3
		# satisfy? is symmetric, it means that the intersection of the
		# available version ranges is non empty
		def satisfy?(other)
			case other
			when Version
				omin=other; omax=other; ominstrict=false; omaxstrict=false
				oname=@name #we assume the name comparison was already done
			else
				other=self.class.create(other)
				omax, omaxstrict=other.max
				omin, ominstrict=other.min
				oname=other.name
			end
			return false unless @name==oname
			min, strict=self.min
			return false if omax and min and (omax < min or omax == min && (strict or omaxstrict))
			max, strict=self.max
			return false if max and omin and (omin > max or omin == max && (strict or ominstrict))
			true
		end

		private def parse(query)
			if (m=query.match(/^([^><=]*)([><=]*)([\w.\-+:]*)([><=]*)([\w.\-+:]*)$/))
				name=m[1]
				op=m[2]
				version=m[3]
				op2=m[4]
				version2=m[5]
				if op.nil?
					name, version=Utils.rsplit(name, '-', 2)
					op="="; op2=nil; version2=nil
				end
				return name, op, version, op2, version2
			else
				raise QueryError.new("Bad query #{query}")
			end
		end
	end
end
