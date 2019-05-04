require 'aur/packages'
require 'aur/makepkg'

module Archlinux
	# class that support installation (ie define install_method)
	class InstallPackageList < PackageList
		def initialize(*args, **opts)
			super
			@install_method=method(:install_method)
		end

		def get_makepkg_list(l)
			MakepkgList.new(l.map {|p| Query.strip(p)}, config: @config)
		end

		def install_method(l, **opts, &b)
			# if we are used as a source, fall back to the upstream method
			if @install_list&.respond_to?(:install_method)
				@install_list.install_method(l, **opts, &b)
			else
				m=get_makepkg_list(l)
				info=opts.delete(:pkgs_info)
				if info
					tops=info[:top_pkgs].keys
					deps=info[:all_pkgs].keys-tops
					#if we cache the makepkg, we need to update both deps and tops
					#in case we did a previous install
					# require 'pry'; binding.pry
					deps.each { |dep| m[Query.strip(dep)]&.asdeps=true }
					tops.each { |dep| m[Query.strip(dep)]&.asdeps=false }
				end
				m=b.call(m) if b #return false to prevent install
				success=m.install(**opts)
				# call post_install hook if all packages succeeded
				if success
					#&.reduce(:&)
					if success == true
						@config.post_install(l, makepkg_list: m, **opts)
					else #this should be a list of success and failures
						l_success=[]
						l.each_with_index do |pkg,i|
							l_success << pkg if success[i]
						end
						@config.post_install(l_success, makepkg_list: m, **opts)
					end
				end
				m
			end
		end
	end

	# cache aur queries
	class AurCache < InstallPackageList

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
				SH.logger.debug "! #{self.class}: Calling aur for infos on: #{pkgs.join(', ')}"
				l=@klass.packages(*pkgs)
				@query_ignore += pkgs - l.names #these don't exist in aur
			end
			r=l.resolve(*queries, ext_query: false, fallback: false)
			return r, l
		end
	end

	# cache MakepkgList and download PKGBUILD dynamically
	class MakepkgCache < InstallPackageList
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

		def get_makepkg_list(l)
			pkgs=l.map {|p| Query.strip(p)}
			# use the cache
			m=MakepkgList.new(pkgs.map {|pkg| @makepkg_list.key?(pkg) ? @makepkg_list[pkg] : pkg}, config: @config)
			@makepkg_list.merge(m.l.values)
			m
		end

		def ext_query(*queries, **opts)
			m=get_makepkg_list(queries)
			m.keep_if {|_k,v| v.exist?} if @select_existing
			m.packages(get: @get_mode).as_ext_query(*queries, full_pkgs: true, **opts)
		end
	end

	# combine Aur and Makepkg caches
	class AurMakepkgCache < InstallPackageList
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

		def get_makepkg_list(l)
			got=l.select {|pkg| @makepkg_cache.key?(pkg)}
			got_m=@makepkg_cache.get_makepkg_list(got)
			rest=@aur_cache.get_makepkg_list(l-got)
			MakepkgList.new(l.map do |name|
				strip=Query.strip(name)
				got_m.key?(strip) ? got_m[strip] : rest[strip]
			end, config: @config)
		end
	end

	class AurPackageList < InstallPackageList
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
	end
end
