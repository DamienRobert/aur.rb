require 'tsort'
require 'time'

module Archlinux

	class PackageClass #meta class for class that hold package infos
		def self.packages(*repos)
			pkgs=PackageList.new
			repos.each do |repo|
				npkg=case repo
				when "@db"
					Archlinux.config.db.packages
				when "@dbdir"
					Archlinux.config.db.dir_packages
				when ":local"
					LocalRepo.new.packages
				when /^(db)?@(r)?get\((.*)\)/
				  recursive=$2; querier=$1; query=$3
				  if querier == "db"
					  new=Archlinux.config.db.packages
					elsif querier == nil
					  new=Archlinux.config.install_list
					else
					  SH.logger.warn "Unknown querier: #{querier}"
					end
					l=query.split(',')
					list=recursive ? new.rget(*l) : new.get(*l)
					new.slice(*list)
				else
					if (m=repo.match(/^:(.*)\Z/))
						Repo.new(m[1]).packages
					else
						path=Pathname.new(repo)
						if path.file?
							PackageFiles.new(path).packages
						elsif path.directory?
							PackageFiles.from_dir(path).packages
						end
					end
				end
				if npkg.nil?
					SH.logger.warn "Unknown repo #{repo}"
				else
					pkgs.merge(npkg)
				end
			end
			pkgs
		end

		def self.packages_list(*repos)
			if repos.length == 2
				pkg1=packages(*repos[0])
				pkg2=packages(*repos[1])
			else
				i=repos.index('::')
				unless i
					SH.logger.warn "Only one list given"
					i=0
				end
				pkg1=packages(*repos[0...i])
				pkg2=packages(*repos[i+1..-1])
			end
			return pkg1, pkg2
		end
	end

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
			return r if r.nil?
			version=self.version
			r+="="+version.to_s if version
			r
		end

    # for a db package, this is the corresponding filename
		def file
			@props[:filename] && Pathname.new(@props[:filename])
		end

    # for a file package, this is the full path
		def path
			file || Pathname.new(@props[:repo])
		end

    # for a db or a file package, this is the full path
		def full_path
		  if file and @props[:repo]
        Pathname.new(@props[:repo]).dirname+file
		  else
		    path
		  end
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
			@ignore=[] #ignore packages update (for config file; for cli see the ignore parameter in install?)
			@unignore=nil
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

		def list(version=false, quiet: false)
			l= version ? keys.sort : names.sort
			if quiet
			  SH.logger.info l.join(' ')
			else
			  l.each do |pkg|
				  SH.logger.info "- #{pkg}"
			  end
			end
		end

		def list_paths(full=false, quiet: false)
			l= full ? values.map {|f| f.full_path}.sort : values.map {|f| f.path}.sort
			if quiet
			  SH.logger.info l.join(' ')
			else
			  l.each do |pkg|
				  SH.logger.info "- #{pkg}"
			  end
	    end
		end

		def name_of(pkg)
			pkg.name_version
		end
		
		def packages
			self
		end

		def same?(other)
			unless @l.keys == other.keys
				SH.logger.warn("#{self.class}: Inconsistency in the package names")
				return false
			end
			r=true
			@l.each do |name, pkg|
				unless pkg.same?(other[name])
					SH.logger.warn("#{self.class}: Inconsistensy for the package #{name}")
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

		def graph(mode=@children_mode)
		  require 'dr/base/graph'
		  g=DR::Graph.new
		  @l.each do |name, pkg|
		    g << {name => pkg.dependencies(mode)}
		  end
		  g
		end

		# select the most appropriate match (does not use ext_query), using #query
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
		# So this is like find, except we respect @query_ignore, and call
		# ext_query for missing packages
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
					fallback_got=self.resolve(*new_queries.values, provides: provides, ext_query: ext_query, fallback: false, log_missing: :verbose, **opts)
					got.merge!(fallback_got)
					SH.log(log_missing, "#{self.class}: Warning! Missing packages: #{missed.map {|m| r=m; r<<" [fallback: #{fallback}]" if (fallback=fallback_got[new_queries[m]]); r}.join(', ')}") unless missed.empty?
				end
			else
				SH.log(log_missing, "#{self.class}: Warning! Missing packages: #{missed.join(', ')}") unless missed.empty?
			end
			got
		end

		# this gives the keys of the packages we resolved
		def get(*args)
			#compact because the resolution can be nil for an ignored package
			resolve(*args).values.compact
		end

		# this gives the values of the packages we resolved
		def get_packages(*args)
			l.values_at(*get(*args))
		end

		def get_package(pkg)
			l[(get(pkg).first)]
		end

		# this is like a 'restrict' operation
		def slice(*args)
			self.class.new(l.slice(*get(*args)), **{})
		end

		# get children (non recursive)
		def children(node, mode=@children_mode, log_level: :verbose2, **opts, &b)
			deps=@l.fetch(node).dependencies(mode)
			SH.log(log_level, "- #{node}: #{deps.join(', ')}")
			deps=get(*deps, **opts)
			SH.log(log_level, "  => #{deps.join(', ')}") unless deps.empty?
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

		def ignore_package?(pkg, ignore: [], unignore: nil)
		  l=lambda do |pkg, ign|
		    case ign
		    when Array
		      ign.include?(pkg)
		    when Regexp
		      ign.match?(pkg)
		    when Proc
		      ign.call(pkg)
		    else
		      raise PackageError.new("ignore_package: unknown ignore: #{ign}")
		    end
		  end
		  return ! l.call(pkg, @unignore) unless @unignore.nil?
		  return ! l.call(pkg, unignore) unless unignore.nil?
		  return true if l.call(pkg, @ignore)
		  return l.call(pkg, ignore)
		end

		def ignore_packages(pkgs, ignore: [], unignore: nil)
		  pkgs.select {|pkg| ! ignore_package?(pkg, ignore: ignore, unignore: unignore)}
		end

		# check updates compared to another list
		def check_updates(l, ignore: [], unignore: nil)
			l=self.class.create(l)
			a=self.latest; b=l.latest
			r={}
			b.each do |k, v|
				next if ignore_package?(k, ignore: ignore, unignore: unignore)
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
				next if ignore_package?(k, ignore: ignore)
				r[k]={op: :obsolete,
					in: a[k].version.to_s,
					out: nil, in_pkg: name_of(a[k])}
			end
			r
		end

		def select_updates(r)
			up=r.select {|_k,v| v[:op]==:upgrade or v[:op]==:install}
			return up.map {|_k, v| v[:out_pkg]}, up
		end

		def get_updates(l, log_level: true, ignore: [], unignore: nil, rebuild: false, **showopts)
			c=check_updates(l, ignore: ignore, unignore: unignore)
			show_updates(c, log_level: log_level, **showopts)
			if rebuild
				# keep all packages
				to_build=c.select {|_k,v| v[:out_pkg]}
				return to_build.map {|_k, v| v[:out_pkg]}, to_build
			else
				select_updates(c)
			end
		end

		#take the result of check_updates and pretty print them
		#no_show has priority over :show
		def show_updates(r, show: [:upgrade, :downgrade, :obsolete, :install], no_show: [], log_level: true)
			r.each do |k,v|
				next unless show.include?(v[:op]) and !no_show.include?(v[:op])
				vin= v[:in] ? v[:in] : "(none)"
				vout= v[:out] ? v[:out] : "(none)"
				op=case v[:op]
				when :downgrade
					"<-"
				when :upgrade, :install, :obsolete
					"->"
				when :equal
					"="
				end
				extra=""
				extra=" [#{v[:op]}]" if v[:op]!=:upgrade

				SH.log(log_level, "  -> #{k}: #{vin} #{op} #{vout}#{extra}")
			end
		end

		# this take a list of packages which can be updates of ours
		# return check_updates of this list (restricted to our current
		# packages, so it won't show any 'install' operation
		def check_update(updates=@install_list, ignore: [], unignore: nil)
			return [] if updates.nil?
			new_pkgs=updates.slice(*names) #ignore 'install' packages
			check_updates(new_pkgs, ignore: ignore, unignore: unignore)
		end

		def update?(**opts)
			install?(update: true, **opts)
		end

		# take a list of packages to install, return the new or updated
		# packages to install with their dependencies
		def install?(*packages, update: false, install_list: @install_list, log_level: true, log_level_verbose: :verbose, ignore: [], rebuild: false, no_show: [:obsolete], **showopts)
			if update
			  up_pkgs=self.names
			  up_pkgs = ignore_packages(up_pkgs, ignore: ignore) #ignore updates of these packages
				packages+=up_pkgs
			end
			if install_list
				unignore = packages.map {|p| Query.strip(p)} #if we specify a package on the command line, consider it even if it is ignored
				SH.log(log_level_verbose, "# Checking packages #{packages.join(', ')}", color: :bold)
				new_pkgs=install_list.slice(*packages)
				u, u_infos=get_updates(new_pkgs, log_level: log_level_verbose, ignore: ignore, unignore: unignore, rebuild: rebuild, no_show: no_show, **showopts)
				# todo: update this when we have a better preference mechanism
				# (then we will need to put @official in the install package class)
				new=self.class.new(l.values).merge(new_pkgs)
				new.chain_query(install_list)
				# The updates or new packages may need new deps
				SH.log(log_level_verbose, "# Checking dependencies of #{u.join(', ')}", color: :bold) unless u.empty?
				full=new.rget(*u)
				SH.log(log_level, "New packages:", color: :bold)
				full_updates, full_infos=get_updates(new.slice(*full), log_level: log_level, ignore: ignore, unignore: unignore, rebuild: rebuild=="full" ? true : false, no_show: no_show, **showopts)
				if rebuild and rebuild != "full" #we need to merge back u
					full_updates |=u
					full_infos.merge!(u_infos)
				end
				infos={top_pkgs: u_infos, all_pkgs: full_infos}
				full_updates, infos=yield full_updates, infos if block_given?
				return full_updates, infos
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
			keys=method(:install?).parameters.select {|arg| arg[0]==:key}.map {|arg| arg[1]}
			keys.each do |key|
				case key
				when :rebuild
					opts.key?(key) && install_opts[key]=opts.fetch(key)
				else
					opts.key?(key) && install_opts[key]=opts.delete(key)
				end
			end
			l, l_info=install?(*args, **install_opts, &callback) #return false in the callback to prevent install
			if @install_method
				@install_method.call(l, pkgs_info: l_info, **opts, &b) unless !l or l.empty?
			else
				return l, l_info
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

end
