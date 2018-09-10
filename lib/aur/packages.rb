require 'aur/makepkg'
require 'tsort'
require 'time'

module Archlinux
	PackageError=Class.new(ArchlinuxError)
	class Package
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		Archlinux.delegate_h(self, :@props)
		attr_reader :name, :props

		def initialize(*args)
			case args.length
			when 2
				name, props=args
			when 1
				props=args.first
				name=nil
			else
				raise PackageError.new("Error the number of arguments should be 1 or 2")
			end
			@name=name
			@props={}
			self.props=(props)
			@name=@props[:name] || @props[:pkgname] || @props[:pkgbase] unless @name
		end

		def props=(props)
			[:groups, :depends, :make_depends, :check_depends, :conflicts, :replaces, :provides, :depends_for, :opt_depends_for].each do |k|
				props.key?(k) or @props[k]=[]
			end
			@props[:opt_depends]||={}
			props.each do |k,v|
				k=Utils.to_snake_case(k.to_s).to_sym
				k=:opt_depends if k==:optdepends || k==:optional_deps
				k=:make_depends if k==:makedepends
				k=:check_depends if k==:checkdepends
				k=:build_date if k==:checkdepends
				k=:depends if k==:depends_on or k==:requires
				k=:conflicts if k==:conflicts_with
				k=:pkgbase if k==:base
				k=:depends_for if k==:required_by
				k=:opt_depends_for if k==:optional_for
				k=:description if k==:desc
				case k
				when :first_submitted, :last_modified, :out_of_date, :build_date, :install_date
					if v and !v.is_a?(Time)
						v= v.is_a?(Integer) ? Time.at(v) : Time.parse(v)
					end
				when :repository, :groups, :depends, :make_depends, :check_depends, :conflicts, :replaces, :provides, :depends_for, :opt_depends_for
					v=Array(v)
				when :opt_depends
					unless v.is_a?(Hash)
						w={}
						Array(v).each do |l|
							l.match(/(\w*)\s+:\s+(.*)/) do |m|
								w[m[1]]=m[2]
							end
						end
						v=w
					end
				end
				@props[k]=v
			end
		end

		def merge(h)
			h.each do |k,v|
				if @props[k].nil? or ((k==:package_size or k==:download_size or k==:installed_size) and (@props[k]=="0.00 B" or @props[k]==0))
					@props[k]=v
				elsif k==:repository
					@props[k]=(Array(@props[k])+v).uniq
				end
			end
			self
		end

		def dependencies(l=%i(depends))
			l.map {|i| a=@props[i]; a.is_a?(Hash) ? a.keys : Array(a)}.flatten.uniq
		end

		def version
			Version.new(@props[:version])
		end

		def name_version
			r=self.name
			version=self.version
			r+="="+version.to_s if version
			r
		end

		def file
			Pathname.new(@props[:filename])
		end

		def same?(other)
			# @props.slice(*(@props.keys - [:repo])) == other.props.slice(*(other.props.keys - [:repo]))
			slice=%i(version description depends provides opt_depends replaces conflicts)
			# p name, other.name, @props.slice(*slice), other.props.slice(*slice)
			name == other.name && @props.slice(*slice) == other.props.slice(*slice)
		end
	end

	class PackageList
		extend CreateHelper

		Archlinux.delegate_h(self, :@l)
		attr_accessor :children_mode, :ext_query, :ignore, :query_ignore, :install_list, :install_method
		attr_reader :l, :versions, :provides_for

		def initialize(list, config: Archlinux.config)
			@l={}
			@versions={} #hash of versions for quick look ups
			@provides_for={} #hash of provides for quick look ups
			@ext_query=nil #how to get missing packages, default
			@children_mode=%i(depends) #children, default
			@ignore=[] #ignore packages update
			@query_ignore=[] #query ignore packages (ie these won't be returned by a query)
			@install_list=nil
			@install_method=nil
			@config=config
			merge(list)
		end

		def names
			@versions.keys
		end

		def name_of(pkg)
			pkg.name_version
		end
		
		def packages
			self
		end

		def same?(other)
			unless @l.keys == other.keys
				SH.logger.warn("Inconsistency in the package names")
				return false
			end
			r=true
			@l.each do |name, pkg|
				unless pkg.same?(other[name])
					SH.logger.warn("Inconsistensy for the package #{name}")
					r=false
				end
			end
			return r
		end

		def merge(l)
			l= case l
				when PackageList
					l.values
				when Hash
					l.values.compact
				else
					l.to_a
				end
			l.each do |pkg|
				pkg=Package.new(pkg) unless pkg.is_a?(Package)
				name=name_of(pkg)
				if @l.key?(name)
					@l[name].merge(pkg)
				else
					@l[name]=pkg
				end

				@versions[pkg.name]||={}
				@versions[pkg.name][pkg.version.to_s]=name

				pkg[:provides].each do |p|
					pkg=Query.strip(p)
					@provides_for[pkg]||={}
					@provides_for[pkg][p]=name #todo: do we pass the name or the full pkg?
				end
			end
			self
		end

		def latest
			r={}
			@versions.each do |pkg, versions|
				v=versions.keys.max do |v1,v2|
					Version.create(v1) <=> Version.create(v2)
				end
				r[pkg]=@l[versions[v]]
			end
			r
		end

		def find(q, **opts)
			return q if @l.key?(q)
			q=Query.create(q); pkg=q.name
			query(q, **opts) do |found, type|
				if type==:version
					unless found.empty? #we select the most up to date
						max = found.max { |v,w| Version.create(v) <=> Version.create(w) }
						return @versions[pkg][max]
					end
				elsif type==:provides
					max = found.max { |v,w| Query.create(v) <=> Query.create(w) }
					return @provides_for[pkg][max]
				end
			end
			return nil
		end

		def query(q, provides: false, &b) #provides: do we check Provides?
			q=Query.new(q) unless q.is_a?(Query)
			matches=[]; pkg=q.name
			if @versions.key?(pkg)
				matches+=(found=@versions[pkg].keys.select {|v| q.satisfy?(Version.create(v))}).map {|k| @versions[pkg][k]}
				yield(found, :version) if block_given?
			end
			if provides and @provides_for.key?(pkg)
				matches+=(found=@provides_for[pkg].keys.select {|v| q.satisfy?(Query.create(v))}).map {|k| @provides_for[pkg][k]}
				yield(found, :provides) if block_given?
			end
			matches
		end

		# here the arguments are Strings
		# return the arguments replaced by eventual provides + missing packages
		# are added to @l
		def resolve(*queries, provides: true, ext_query: @ext_query, fallback: true, **opts)
			got={}; missed=[]
			pkgs=queries.map {|p| Query.strip(p)}
			ignored = pkgs & @query_ignore
			queries.each do |query|
				if ignored.include?(Query.strip(query))
					got[query]=nil #=> means the query was ignored
				else
					pkg=self.find(query, provides: provides, **opts)
					if pkg
						got[query]=pkg
					else
						missed << query
					end
				end
			end
			# we do it this way to call ext_query in batch
			if ext_query and !missed.empty?
				found, new_pkgs=ext_query.call(*missed, provides: provides)
				self.merge(new_pkgs)
				got.merge!(found)
				missed-=found.keys
			end
			if fallback and !missed.empty?
				new_queries={}
				missed.each do |query|
					if (query_pkg=Query.strip(query)) != query
						new_queries[query]=query_pkg
						# missed.delete(query)
					end
				end
				unless new_queries.empty?
					SH.logger.warn "Trying fallback for packages: #{new_queries.keys.join(', ')}"
					fallback_got=self.resolve(*new_queries.values, provides: provides, ext_query: ext_query, fallback: false, **opts)
					got.merge!(fallback_got)
					SH.logger.warn "Missing packages: #{missed.map {|m| r=m; r<<" [fallback: #{fallback}]" if (fallback=fallback_got[new_queries[m]]); r}.join(', ')}"
				end
			else
				SH.logger.warn "Missing packages: #{missed.join(', ')}" if !missed.empty? and ext_query != false #ext_query=false is a hack to silence this message
			end
			got
		end

		# this gives the keys
		def get(*args)
			#compact because the resolution can be nil for an ignored package
			resolve(*args).values.compact
		end

		# this gives the values
		def get_packages(*args)
			l.values_at(*get(*args))
		end

		# this is like a 'restrict' operation
		def slice(*args)
			self.class.new(@l.slice(*get(*args)))
		end

		def children(node, mode=@children_mode, verbose: false, **opts, &b)
			deps=@l.fetch(node).dependencies(mode)
			SH.logger.info "- #{node} => #{deps}" if verbose
			deps=get(*deps, **opts)
			SH.logger.info " => #{deps}" if verbose
			if b
				deps.each(&b)
			else
				deps
			end
		end

		private def call_tsort(l, method: :tsort, **opts, &b)
			each_node=l.method(:each)
			s=self
			each_child = lambda do |node, &b|
				s.children(node, **opts, &b)
			end
			TSort.public_send(method, each_node, each_child, &b)
		end

		def tsort(l, **opts, &b)
			if b
				call_tsort(l, method: :each_strongly_connected_component, **opts, &b)
			else
				r=call_tsort(l, method: :strongly_connected_components, **opts)
				cycles=r.select {|c| c.length > 1}
				SH.logger.warn "Cycles detected: #{cycles}" unless cycles.empty?
				r.flatten
			end
		end

		# recursive get
		def rget(*pkgs)
			l=get(*pkgs)
			tsort(l)
		end

		# check updates compared to another list
		def check_updates(l, ignore: @ignore)
			l=self.class.create(l)
			a=self.latest; b=l.latest
			r={}
			b.each do |k, v|
				next if ignore.include?(k)
				if a.key?(k)
					v1=a[k].version
					v2=v.version
					h={in: v1.to_s, out: v2.to_s, in_pkg: name_of(a[k]), out_pkg: name_of(v)}
					case v1 <=> v2
					when -1
						h[:op]=:upgrade
					when 0
						h[:op]=:equal
					when 1
						h[:op]=:downgrade
					end
					r[k]=h
				else
					#new installation
					r[k]={op: :install,
						in: nil,
						out: v.version.to_s, out_pkg: name_of(v)}
				end
			end
			(a.keys-b.keys).each do |k|
				next if ignore.include?(k)
				r[k]={op: :obsolete,
					in: a[k].version.to_s,
					out: nil, in_pkg: name_of(a[k])}
			end
			r
		end

		def select_updates(r)
			r.select {|_k,v| v[:op]==:upgrade or v[:op]==:install}.map {|_k, v| v[:out_pkg]}
		end

		def get_updates(l, verbose: true, obsolete: true, ignore: @ignore)
			c=check_updates(l, ignore: ignore)
			show_updates(c, obsolete: obsolete) if verbose
			select_updates(c)
		end

		#take the result of check_updates and pretty print them
		def show_updates(r, obsolete: true)
			require 'simplecolor'
			r.each do |k,v|
				next if v[:op]==:equal
				next if obsolete and v[:op]==:obsolete
				vin= v[:in] ? v[:in] : "(none)"
				vout= v[:out] ? v[:out] : "(none)"
				op = "->"; op="<-" if v[:op]==:downgrade
				extra=""
				extra=" [#{v[:op]}]" if v[:op]!=:upgrade
				SH.logger.info SimpleColor.color("  -> #{k}: #{vin} #{op} #{vout}#{extra}", :black)
			end
		end

		# this take a list of packages which can be updates of ours
		def check_update(updates=@install_list, ignore: @ignore)
			return [] if updates.nil?
			new_pkgs=updates.slice(*packages)
			check_updates(new_pkgs, ignore: ignore)
		end

		def update(**opts)
			install(update: true, **opts)
		end

		# take a list of packages to install
		def install(*packages, update: false, install_list: @install_list, verbose: true, obsolete: true, ignore: @ignore)
			packages+=self.names if update
			if install_list
				ignore -= packages.map {|p| Query.strip(p)}
				new_pkgs=install_list.slice(*packages)
				SH.logger.info "# Checking packages" if verbose
				u=get_updates(new_pkgs, verbose: verbose, obsolete: obsolete, ignore: ignore)
				new=self.class.new(l.values).merge(new_pkgs)
				# The updates or new packages may need new deps
				SH.logger.info "# Checking dependencies" if verbose
				full=new.rget(*u)
				# full_updates=get_updates(new.values_at(*full), verbose: verbose, obsolete: obsolete)
				full_updates=get_updates(new.slice(*full), verbose: verbose, obsolete: obsolete, ignore: ignore)
				full_updates=yield full_updates, u if block_given?
				full_updates
			else
				SH.logger.warn "External install list not defined"
			end
		end

		def do_update(**opts, &b)
			do_install(update: true, **opts, &b)
		end

		def do_install(*args, callback: nil, **opts)
			install_opts={}
			%i(update ext_query verbose obsolete).each do |key|
				opts.key?(key) && install_opts[key]=opts.delete(key)
			end
			l=install(*args, **install_opts, &callback) #return false in the callback to prevent install
			if @install_method
				@install_method.call[l, &b] unless !l or l.empty?
			end
		end
	end

	class AurCache < PackageList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def initialize(l=[])
			super
			@ext_query=method(:ext_query)
			@query_ignore=AurPackageList.official
		end

		def ext_query(*queries, provides: false)
			pkgs=queries.map {|p| Query.strip(p)}
			# in a query like foo>1000, even if foo exist and was queried,
			# the query fails so it gets called in ext_query
			# remove these packages
			# TODO: do the same for a provides query
			pkgs-=self.names
			if pkgs.empty?
				l=self.class.new([])
			else
				SH.logger.warn "! Calling aur for infos on: #{pkgs.join(', ')}"
				l=AurQuery.packages(*pkgs)
				@query_ignore += pkgs - l.names #these don't exist in aur
			end
			r=l.resolve(*queries, ext_query: false, fallback: false)
			return r, l
		end
	end

	class AurPackageList < PackageList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def self.official
			@official||=%w(core extra community).map {|repo| Repo.new(repo).list(mode: :pacman)}.flatten.compact
		end

		def self.cache
			@cache ||= AurCache.new([])
		end

		def initialize(l)
			super
			@install_list=self.class.cache
			@children_mode=%i(depends make_depends check_depends)
			@install_method=method(:install_method)
		end

		def install_method(l)
			m=MakepkgList.new(l.map {|p| Query.strip(p)}, config: @config)
			if block_given?
				m=yield m #return false to prevent install
			end
			m.install(**opts) if m
			m
		end

		def do_install(*args, callback: nil, **opts)
			deps=[]
			our_callback = lambda do |with_deps, orig|
				deps=with_deps-orig
				callback.call(orig, with_deps)
				with_deps #we don't want to modify the installed packages
			end
			super(*args, callback: our_callback, **opts) do |m|
				deps.each { |dep| m[Query.strip(dep)]&.asdeps=true }
				m=yield m if block_given?
				m
			end
		end

		def official
			self.class.official
		end
	end
end
