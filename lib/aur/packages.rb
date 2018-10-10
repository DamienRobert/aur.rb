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
				k=:opt_depends if k==:optdepends or k==:optdepend or k==:optional_deps
				k=:make_depends if k==:makedepends or k==:makedepend
				k=:check_depends if k==:checkdepends or k==:checkdepend
				k=:build_date if k==:builddate
				k=:depends if k==:depends_on or k==:requires
				k=:conflicts if k==:conflicts_with
				k=:pkgbase if k==:base
				k=:depends_for if k==:required_by
				k=:opt_depends_for if k==:optional_for
				k=:description if k==:desc or k==:pkgdesc
				case k
				when :first_submitted, :last_modified, :out_of_date, :build_date, :install_date
					if v and !v.is_a?(Time)
						v= v.is_a?(Integer) ? Time.at(v) : Time.parse(v)
					end
				when :repository, :groups, :depends, :make_depends, :check_depends, :conflicts, :replaces, :provides, :depends_for, :opt_depends_for, :license, :source
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
			if !@props[:version] and @props[:pkgver]
				@props[:version]=Version.new(@props[:epoch], @props[:pkgver], @props[:pkgrel]).to_s
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
			@props[:filename] && Pathname.new(@props[:filename])
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
		attr_accessor :children_mode, :ext_query, :ignore, :query_ignore, :install_list, :install_method, :install_list_of
		attr_reader :l, :versions, :provides_for

		def initialize(list=[], config: Archlinux.config)
			@l={}
			@versions={} #hash of versions for quick look ups
			@provides_for={} #hash of provides for quick look ups
			@ext_query=nil #how to get missing packages, default
			@children_mode=%i(depends) #children, default
			@ignore=[] #ignore packages update
			@query_ignore=[] #query ignore packages (ie these won't be returned by a query; so stronger than @ignore)
			@install_list=nil #how do we check for new packages / updates
			@install_list_of=nil #are we used to check for new packages / updates
			@install_method=nil #how to install stuff
			@config=config
			merge(list)
		end

		# the names without the versions. Use self.keys to get the name=version
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
					#todo: we need a list here
				end
			end
			self
		end

		# return all packages that provides for pkg
		# this is more complicated than @provides_for[pkg]
		# because if b provides a and c provides a, then pacman assumes that b
		# provides c
		def all_provides_for(pkg)
			provides=l.fetch(pkg,{}).fetch(:provides,[]).map {|q| Query.strip(q)}
			provided=([Query.strip(pkg)]+provides).flat_map do |prov|
				@provides_for.fetch(prov,{}).values.map {|v| Version.strip(v)}
			end.uniq
			provided
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

		# select the most appropriate match
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

		# output all matches (does not use ext_query)
		def query(q, provides: false) #provides: do we check Provides?
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
		def resolve(*queries, provides: true, ext_query: @ext_query, fallback: true, log_missing: :warn, log_fallback: :warn, **opts)
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
					SH.log(log_fallback, "Trying fallback for packages: #{new_queries.keys.join(', ')}")
					fallback_got=self.resolve(*new_queries.values, provides: provides, ext_query: ext_query, fallback: false, log_missing: :quiet, **opts)
					got.merge!(fallback_got)
					SH.log(log_missing, "Missing packages: #{missed.map {|m| r=m; r<<" [fallback: #{fallback}]" if (fallback=fallback_got[new_queries[m]]); r}.join(', ')}") unless missed.empty?
				end
			else
				SH.log(log_missing, "Missing packages: #{missed.join(', ')}") unless missed.empty?
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

		def get_package(pkg)
			l[(get(pkg).first)]
		end

		# this is like a 'restrict' operation
		def slice(*args)
			self.class.new(l.slice(*get(*args)))
		end

		def children(node, mode=@children_mode, verbose: :quiet, **opts, &b)
			deps=@l.fetch(node).dependencies(mode)
			SH.log(verbose, "- #{node} => #{deps}")
			deps=get(*deps, **opts)
			SH.log(verbose, " => #{deps}")
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
		# return check_updates of this list (restricted to our current
		# packages, so it won't show any 'install' operation
		def check_update(updates=@install_list, ignore: @ignore)
			return [] if updates.nil?
			new_pkgs=updates.slice(*names) #ignore 'install' packages
			check_updates(new_pkgs, ignore: ignore)
		end

		def update?(**opts)
			install?(update: true, **opts)
		end

		# take a list of packages to install, return the new or updated
		# packages to install with their dependencies
		def install?(*packages, update: false, install_list: @install_list, verbose: true, obsolete: true, ignore: @ignore)
			packages+=self.names if update
			if install_list
				ignore -= packages.map {|p| Query.strip(p)}
				SH.log(verbose, "# Checking packages #{packages.join(', ')}")
				new_pkgs=install_list.slice(*packages)
				u=get_updates(new_pkgs, verbose: verbose, obsolete: obsolete, ignore: ignore)
				new=self.class.new(l.values).merge(new_pkgs)
				new.chain_query(install_list)
				# The updates or new packages may need new deps
				SH.log(verbose, "# Checking dependencies of #{u.join(', ')}")
				full=new.rget(*u)
				# full_updates=get_updates(new.values_at(*full), verbose: verbose, obsolete: obsolete)
				full_updates=get_updates(new.slice(*full), verbose: verbose, obsolete: obsolete, ignore: ignore)
				full_updates=yield full_updates, u if block_given?
				full_updates
			else
				SH.logger.warn "External install list not defined"
			end
		end

		def update(**opts, &b)
			install(update: true, **opts, &b)
		end

		# the callback is passed to install? while the block is passed to
		# @install_method
		def install(*args, callback: nil, **opts, &b)
			install_opts={}
			%i(update ext_query verbose obsolete).each do |key|
				opts.key?(key) && install_opts[key]=opts.delete(key)
			end
			l=install?(*args, **install_opts, &callback) #return false in the callback to prevent install
			if @install_method
				@install_method.call(l, **opts, &b) unless !l or l.empty?
			else
				l
			end
		end

		#returns a Proc that can be used for another PackageList as an ext_query
		def to_ext_query
			method(:as_ext_query)
		end

		def chain_query(ext_query)
			ext_query=ext_query.to_ext_query if ext_query.is_a?(PackageList)
			if @ext_query
				orig_query=@ext_query
				@ext_query = lambda do |*args, **opts|
					r, l=orig_query.call(*args, **opts)
					missed = args-r.keys
					r2, l2=ext_query.call(*missed, **opts)
					return r.merge(r2), l.merge(l2)
				end
			else
				@ext_query=ext_query
			end
		end

		# essentially just a wrapper around resolve
		def as_ext_query(*queries, provides: false, full_pkgs: false)
			r=self.resolve(*queries, provides: provides, fallback: false)
			# puts "#{self.class}: #{queries} => #{r}"
			l= full_pkgs ? @l : slice(*r.values.compact)
			return r, l
		end

	end

	# cache aur queries
	class AurCache < PackageList

		def initialize(*args)
			super
			@ext_query=method(:ext_query)
			#@query_ignore=AurPackageList.official
			if @config[:aur_url]==GlobalAurCache.config[:aur_url]
				@klass=GlobalAurCache
			else
				@klass=AurQueryCustom.new(config: @config)
			end
		end

		def ext_query(*queries, **_opts)
			pkgs=queries.map {|p| Query.strip(p)}
			# in a query like foo>1000, even if foo exist and was queried,
			# the query fails so it gets called in ext_query
			# remove these packages
			# TODO: do the same for a provides query
			pkgs-=self.names
			if pkgs.empty?
				l=self.class.new([])
			else
				SH.logger.warn "! AurCache: Calling aur for infos on: #{pkgs.join(', ')}"
				l=@klass.packages(*pkgs)
				@query_ignore += pkgs - l.names #these don't exist in aur
			end
			r=l.resolve(*queries, ext_query: false, fallback: false)
			return r, l
		end
	end

	# cache MakepkgList and download PKGBUILD dynamically
	class MakepkgCache < PackageList
		attr_accessor :select_existing, :get_mode, :makepkg_list
		def initialize(*args, get_mode: {}, **opts)
			super(*args, **opts)
			# puts "MakepkgCache called with options: #{[args, get_mode]}"
			@select_existing=get_mode.delete(:existing)
			@get_mode=get_mode
			@ext_query=method(:ext_query)
			@makepkg_list=MakepkgList.new([], config: @config)
			#@query_ignore=AurPackageList.official
		end

		def ext_query(*queries, **opts)
			pkgs=queries.map {|p| Query.strip(p)}
			pkgs=MakepkgList.new(pkgs).values.select {|m| m.exist?} if @select_existing
			m=MakepkgList.new(pkgs, config: @config)
			@makepkg_list.merge(m.l.values)
			m.packages(get: @get_mode).as_ext_query(*queries, full_pkgs: true, **opts)
		end
	end

	# combine Aur and Makepkg caches
	class AurMakepkgCache < PackageList
		attr_accessor :aur_cache, :makepkg_cache
		def initialize(*args, **opts)
			super
			@aur_cache = AurCache.new(**opts)
			@makepkg_cache = MakepkgCache.new(get_mode: {update: true, clone: true, pkgver: true, view: true}, **opts)
			@ext_query=method(:ext_query)
			#@query_ignore=AurPackageList.official
		end

		def ext_query(*queries, **opts)
			devel=queries.select do |query|
				Query.strip(query)=~/(-git|-hg|-svn)$/
			end
			if @install_list_of
				# we only want to check the pkgver of packages we already have; for
				# the others the aur version is enough
				devel=devel & @install_list_of.names
			end
			aur=queries-devel
			r1, l1=@makepkg_cache.as_ext_query(*devel, **opts)
			missing=devel-r1.keys
			r2, l2=@aur_cache.as_ext_query(*(missing+aur), **opts)
			return r1.merge(r2), l1.merge(l2)
		end

		def install_method(l, **opts, &b)
			striped=l.map {|p| Query.strip(p)}
			# preserve the feature of the already downloaded makepkg lists
			# in particular if we need custom get_pkg to get metadata, we keep
			# them for installation
			got=@makepkg_cache.makepkg_list.l.slice(*striped)
			# we need to preserver order here
			#missing=striped-got.keys
			#m=MakepkgList.new(got.values+missing, config: @config)
			m=MakepkgList.new(striped.map {|i| got.key?(i) ? got[i] : i}, config: @config)
			m=b.call(m) if b #return false to prevent install
			m.install(**opts) if m
			m
		end
	end

	class AurPackageList < PackageList
		# def self.cache
		# 	@cache ||= AurCache.new([])
		# end

		def self.official
			@official||=%w(core extra community).map {|repo| Repo.new(repo).list(mode: :pacman)}.flatten.compact
		end

		def initialize(*args, **opts)
			super
			# @install_list=self.class.cache
			@install_list=@config.install_list #AurMakepkgCache.new(**opts)
			# TODO this won't work if we use several PackageList with the same
			# cache at the same time
			@install_list.install_list_of=self
			@children_mode=%i(depends make_depends check_depends)
			@install_method=method(:install_method)
			@query_ignore=official
		end

		def official
			self.class.official
		end

		def install_method(l, **opts, &b)
			if @install_list&.respond_to?(:install_method)
				@install_list.install_method(l, **opts, &b)
			else
				# fallback to consider everything from aur
				m=MakepkgList.new(l.map {|p| Query.strip(p)}, config: @config)
				m=b.call(m) if b #return false to prevent install
				m.install(**opts) if m
				m
			end
		end

		def install(*args, callback: nil, **opts)
			deps=[]
			our_callback = lambda do |with_deps, orig|
				deps=with_deps-orig
				callback.call(with_deps, orig) if callback
				with_deps #we don't want to modify the installed packages
			end
			super(*args, callback: our_callback, **opts) do |m|
				deps.each { |dep| m[Query.strip(dep)]&.asdeps=true }
				m=yield m if block_given?
				m
			end
		end

	end
end
