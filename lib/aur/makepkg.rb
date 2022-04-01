require 'aur/devtools'
require 'aur/packages'
require 'uri'
require 'tmpdir'

module Archlinux
	# this is a get class; it should respond to update and clone
	class Git
		extend CreateHelper
		attr_accessor :dir, :config, :logdir
		attr_writer :url

		def initialize(dir, url: nil, logdir: nil, config: Archlinux.config)
			@dir=Pathname.new(dir)
			@url=url
			@config=config
			@logdir=logdir
		end

		def url
		  url=URI.parse(@url)
			url.relative? ? URI(@config[:aur_url])+"#{@url}.git" : url
		end

		def call(*args,**opts,&b)
			opts[:method]||=:sh
			begin
			  @dir.chdir do
				  @config.launch(:git, *args, **opts, &b)
			  end
			rescue => e
				SH.logger.error("Error in running git: #{e}")
				return false
			end
		end

		# callbacks called by makepkg
		def done_view
			call('branch', '-f', 'aur_view', 'HEAD')
		end
		def done_build
			call('branch', '-f', 'aur_build', 'HEAD')
		end

		def write_patch(logdir)
			(logdir+"#{@dir.basename}").on_ln_s(@dir.realpath, rm: :symlink)
			if call("rev-parse", "--verify", "aur_view", method: :run_success, quiet: true)
				SH::VirtualFile.new("orderfile", "PKGBUILD").create(true) do |tmp|
					patch=call("diff", "-O#{tmp}", "aur_view", "HEAD", method: :run_simple)
					(logdir+"#{@dir.basename}.patch").write(patch) unless patch.empty?
				end
			end
		end

		def do_update
		  # not: with --devel we already update the PKGBUILD to check for
		  # pkgver() update; so we should not hard reset afterwards.
		  if @did_update
		    return true
		  else
		    @did_update=true
			  # we need to hard reset, because vercmp may have changed our PKGBUILD
			  # todo: only reset when there is an update?

			  # lets try with a theirs merge strat
			  # -> still does not work: error: Your local changes to the following files would be overwritten by merge: PKGBUILD
			  ## suc, _r=call("pull", "-X", "theirs")
			  call("reset", "--hard")
			  suc, _r=call("pull")
			  suc
			end
		end

		def do_clone(url)
			#we cannot call 'call' here because the folder does not yet exist
			suc, _r=@config.launch(:git, "clone", url, @dir, method: :sh)
			suc
		end

		def update(logdir: nil)
			if do_update
				write_patch(logdir) if logdir
			else
				SH.logger.error("Error in updating #{@dir}")
			end
		end

		def clone(url: self.url, logdir: nil)
			if do_clone(url)
				(logdir+"!#{@dir.basename}").on_ln_s(@dir.realpath) if logdir
			else
				SH.logger.error("Error in cloning #{url} to #{@dir}")
			end
		end
	end

	module MakepkgCommon
		#functions common to Makepkg and MakepkgList

		def add_to_db(db=@config.db, force_sign: false)
			unless db.is_a?(DB)
				SH.logger.error "Bad database #{db}, can't add to database"
			else
				db.add(*list.select {|l| r=l.exist?; SH.logger.warn "Package #{l} not built, not adding to the db #{db.repo_name}" unless r; r}, force_sign: force_sign)
				true #do return false if there were errors
			end
		end

	end

	class Makepkg
		extend CreateHelper
		include MakepkgCommon
		attr_accessor :dir, :base, :env, :config, :asdeps
		attr_writer :get_pkg

		def initialize(dir, config: Archlinux.config, env: {}, asdeps: false)
			@dir=Pathname.new(dir)
			@base=@dir.basename #the corresponding pkgbase
			@config=config
			@env=env
			@asdeps=asdeps
			db=@config.db
			@env['PKGDEST']=db.dir.to_s if db
		end

		# should respond to clone, update
		# and optionally done_view, done_build
		def get_pkg
			#@get_pkg||=@config[:default_get_class].new(@dir, url: name, config: @config)
			@get_pkg ||= Archlinux.create_class(@config[:default_get_class], @dir, url: name, config: @config)
		end

		def name
			@base.to_s
		end

		def pkgbuild
			@dir+"PKGBUILD"
		end

		def exist?
			pkgbuild.exist?
		end

		def raw_call(*args, method: :run_simple, **opts)
			@config.launch(:makepkg, *args, **opts) do |*args, **opts|
				@dir.chdir do
					SH.public_send(method, @env, *args, **opts)
				end
			end
		end

		# raw call to makepkg
		def makepkg(*args, **opts)
		  begin
			  raw_call(*args, method: :sh, **opts)
			rescue => e
				SH.logger.error("Error in running makepkg: #{e}")
				return false
			end
		end

		def call(*args, **opts)
			tools=@config.local_devtools #this set up pacman and makepkg config files
			env=opts.delete(:env) || {}
			opts[:method]||=:run_simple
			begin
			  @dir.chdir do
				  tools.makepkg(*args, env: @env.merge(env), **opts)
			  end
			rescue => e
				SH.logger.error("Error in calling makepkg: #{e}")
				return false
			end
		end

		def info(get: false)
			if get
				get_options={}
				get_options=get if get.is_a?(Hash)
				self.get(**get_options)
			end
			stdin=call("--printsrcinfo", chomp: :lines)
			return {pkgs: {}} if stdin.empty?
			mode=nil; r={}; current={}; pkgname=nil
			stdin.each do |l|
				key, value=l.split(/\s*=\s*/,2)
				next if key.nil?
				if key=="pkgbase"
					mode=:pkgbase
					current[:pkgbase]=value
					current[:repo]=@dir
				elsif key=="pkgname"
					if mode==:pkgbase
						r=current
						r[:pkgs]={}
					else
						r[:pkgs][pkgname]=current
					end
					current={}; mode=:pkgname; pkgname=value
				else
					key=key.strip.to_sym
					Archlinux.add_to_hash(current, key, value)
				end
			end
			r[:pkgs][pkgname]=current #don't forget to update the last one
			r
		end

		def packages(refresh=false, get: false)
			@packages=nil if refresh
			unless @packages
				r=info(get: get)
				pkgs=r.delete(:pkgs)
				# r[:pkgbase]
				base=Package.new(r)
				list=pkgs.map do |name, pkg|
					pkg[:name]=name
					Package.new(pkg).merge(base)
				end
				@packages=@config.to_packages(list)
			end
			@packages
		end

		def get(logdir: nil, view: false, update: true, clone: true, pkgver: false)
			if logdir
				logdir=Pathname.new(logdir)
				logdir.mkpath
			end
			get_pkg=self.get_pkg

			if @dir.exist? and update
				get_pkg.update(logdir: logdir)
			elsif !@dir.exist? and clone
				get_pkg.clone(logdir: logdir)
			end
			if view #view before calling pkgver
				r=@config.view(@dir)
				get_pkg.done_view if r and get_pkg.respond_to?(:done_view)
			else
				r=true
			end
			if r and pkgver and pkgver?
				get_source
			else
				return r #abort pkgver
			end
		end

		# shortcut
		def edit
			get(view: true, update: false, clone: true, pkgver: false)
		end
		def edit_pkgbuild
			get(view: false, update: false, clone: true, pkgver: false)
			#TODO: @config.view_file/view_dir?
			@config.view(@dir+"PKGBUILD")
		end

		def pkgver?
			exist? and pkgbuild.read.match(/^\s*pkgver()/)
		end

		def get_source
			success, _r=call('--nodeps', '--nobuild', method: :sh)
			success
		end

		def make(*args, sign: config&.use_sign?(:package), default_opts: [], force: false, asdeps: @asdeps, **opts)
			default_opts << "--sign" if sign
			default_opts << "--key=#{sign}" if sign.is_a?(String)
			default_opts << "--force" if force
			default_opts << "--asdeps" if asdeps
			default_opts+=@config[:makepkg][:build_args]

			# error=13 means the package is already built, we consider that a success
			success, _r=call(*args, method: :sh, default_opts: default_opts, env: @env, expected: 13, **opts)
			get_pkg.done_build if success and get_pkg.respond_to?(:done_build)
			success
		end

		def mkarchroot
			args=@config.dig(:chroot, :packages) || ["base-devel"]
			@config.chroot_devtools.mkarchroot(*args)
		end

		def makechroot(*args, sign: @config&.use_sign?(:package), force: false, **opts)
		  begin
			  unless force
				  if list.all? {|f| f.exist?}
					  SH.logger.info "Skipping #{@dir} since it is already built (use force=true to override)"
					  return true #consider this a success build
				  end
			  end
			  devtools=@config.chroot_devtools
			  success=false
			  @dir.chdir do
				  success=devtools.makechrootpkg(*args, env: @env, **opts)
			  end
			  ## signing should be done by 'build'
			  # self.sign(sign_name: sign) if sign and success
			  success
			rescue => e
				SH.logger.error("Error in running makechroot: #{e}")
				return false
			end
		end

		def build(*makepkg_args, mkarchroot: false, chroot: @config.dig(:chroot, :active), **opts)
			force_sign = opts.delete(:rebuild) #when rebuilding we need to regenerate the signature
			SH.logger.important "=> Building #{@dir}"
			if chroot
				self.mkarchroot if mkarchroot
				success, _r=makechroot(*makepkg_args, **opts)
			else
				success, _r=make(*makepkg_args, **opts)
			end
			if success and (db=@config.db)
				success=add_to_db(db, force_sign: force_sign)
				if !chroot #sync db so that the new versions are available
					tools=@config.local_devtools
					tools.sync_db(db.repo_name)
				end
			end
			if success
				packages.l.keys #return the list of built package
				# TODO better handling of split dirs
			else
				success
			end
		end

		def install(*args, view: true, **opts)
			r=get(view: view)
			if r
				build(*args, **opts)
			else
				r
			end
		end

		def list(**opts)
			call("--packagelist", chomp: :lines, err: "/dev/null", **opts).map {|f| Pathname.new(f)}
		end

		def sign(sign_name: :package, **opts)
			@config.sign(*list.select {|f| f.file?}, sign_name: sign_name, **opts)
		end

	end

	class MakepkgList
		extend CreateHelper
		include MakepkgCommon
		Archlinux.delegate_h(self, :@l)
		attr_accessor :config, :cache, :l

		def self.from_dir(dir=nil, config: Archlinux.config)
			l=[]
			dir=config.cachedir if dir.nil?
			dir.children.each do |child|
				if child.directory? and (child+"PKGBUILD").file?
					l << child
				end
			end
			self.new(l, config: config)
		end

		def initialize(l=[], config: Archlinux.config, cache: config.cachedir)
			@config=config
			@cache=Pathname.new(cache) if cache #how relative filenames are resolved; pass nil to use current dir
			@l={}
			merge(l)
		end

		def merge(l)
			l.each do |m|
				unless m.is_a?(Makepkg)
					m=Pathname.new(m)
					m = @cache+m if m.relative? and @cache
					m=Makepkg.new(m, config: @config)
				end
				@l[m.name]=m
			end
		end

		def packages(refresh=false, get: false)
			@packages = nil if refresh
			if get
				get_options={}
				get_options=get if get.is_a?(Hash)
				self.get(**get_options)
			end
			@packages ||= @l.values.reduce(@config.to_packages) do |list, makepkg|
				list.merge(makepkg.packages(get: false))
			end
		end

		def get(*_args, view: true, pkgver: false, **opts)
			Dir.mktmpdir("aur_view") do |d|
				@l.values.each do |l|
					l.get(*_args, logdir: d, view: false, pkgver: false, **opts) #l.get does not take arguments, we put them here for arg/opt ruby confusion
				end
				if view
					r=@config.view(d)
					if r
						@l.values.each do |l|
							l.get_pkg.done_view if l.get_pkg.respond_to?(:done_view)
						end
					end
				else
					r=true
				end
				if r and pkgver
					@l.values.map do |l| #all?
						l.get_source if l.pkgver?
					end
				end
				return r
			end
		end

		def make(*args)
			@l.values.each do |l|
				l.make(*args)
			end
		end

		def makechroot(*args)
			@l.values.each do |l|
				l.makechroot(*args)
			end
		end

		def mkarchroot
			args=@config.dig(:chroot, :packages) || ["base-devel"]
			@config.chroot_devtools.mkarchroot(*args)
		end

		def list
			@l.values.flat_map { |l| l.list }
		end

		def build(*args, chroot: @config.dig(:chroot, :active), install: false, **opts)
			@config.pre_install(*args, makepkg_list: self, install: install, **opts)
			mkarchroot if chroot
			built=@l.values.map do |l|
				l.build(*args, chroot: chroot, **opts)
			end
			l_success=built.flat_map { |pkgs| pkgs || []}
			@config.post_install(l_success, makepkg_list: self, install: install, **opts)
			built
		end

		# Note that in build @config.{pre,post}_install is called
		def pre_build(*args, **opts)
		end

		def post_build(*args, **opts)
		end


		def install(*args, view: true, **opts)
			r=get(view: view)
			pre_build(*args, **opts)
			build(*args, **opts) if r
			post_build(*args, **opts)
		end
	end
end
