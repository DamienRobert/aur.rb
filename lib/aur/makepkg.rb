require 'aur/config'
require 'aur/devtools'
require 'aur/packages'

module Archlinux
	class Makepkg
		extend CreateHelper
		attr_accessor :dir, :base, :env, :config, :asdeps

		def initialize(dir, config: Archlinux.config, env: {}, asdeps: false)
			@dir=Pathname.new(dir)
			@base=@dir.basename
			@config=config
			@env=env
			@asdeps=asdeps
			db=@config.db
			@env['PKGDEST']=db.dir.to_s if db
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
			raw_call(*args, method: :sh, **opts)
		end

		def call(*args, **opts)
			tools=@config.makepkg_config #this set up pacman and makepkg config files
			env=opts.delete(:env) || {}
			opts[:method]||=:run_simple
			@dir.chdir do
				tools.makepkg(*args, env: @env.merge(env), **opts)
			end
		end

		def info(get: false)
			if get
				get_options={}
				get_options=get if get.is_a?(Hash)
				self.get(**get_options)
			end
			stdin=call("--printsrcinfo", chomp: :lines)
			mode=nil; r={}; current={}; pkgbase=nil; pkgname=nil
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

		def url
			@config[:aur_url]+@base.to_s+".git"
		end

		def get(logdir: nil, view: false, update: true, clone: true, pkgver: false)
			if logdir
				logdir=DR::Pathname.new(logdir)
				logdir.mkpath
			end
			if @dir.exist? and update
				# TODO: what if @dir exist but is not a git directory?
				@dir.chdir do
					unless @config.git_update
						SH.logger.error("Error in updating #{@dir}")
					end
					if logdir
						SH::VirtualFile.new("orderfile", "PKGBUILD").create(true) do |tmp|
							patch=SH.run_simple("git diff -O#{tmp} HEAD@{1}")
							(logdir+"#{@dir.basename}.patch").write(patch) unless patch.empty?
							(logdir+"#{@dir.basename}").on_ln_s(@dir.realpath, rm: :symlink)
						end
					end
				end
			elsif !@dir.exist? and clone
				unless @config.git_clone(url, @dir)
					SH.logger.error("Error in cloning #{url} to #{@dir}")
				end
				if logdir
					(logdir+"!#{@dir.basename}").on_ln_s(@dir.realpath)
				end
			end
			if pkgver? and pkgver
				get_source
			end
			if view
				return @config.view(@dir)
			else
				return true
			end
		end

		def pkgver?
			exist? and pkgbuild.read.match(/^\s*pkgver()/)
		end

		def get_source
			success, _r=call('--nobuild', method: :sh)
			success
		end

		def make(*args, sign: config.use_sign(:package), default_opts: [], force: false, asdeps: @asdeps, **opts)
			default_opts << "--sign" if sign
			default_opts << "--key=#{sign}" if sign.is_a?(String)
			default_opts << "--force" if force
			default_opts << "--asdeps" if asdeps

			success, _r=call(*args, method: :sh, default_opts: default_opts, env: @env, **opts)
			success
		end

		def mkarchroot
			args=@config.dig(:chroot, :packages) || ["base-devel"]
			@config.devtools.mkarchroot(*args)
		end

		def makechroot(*args, sign: @config.use_sign(:package), force: false, **opts)
			unless force
				if list.all? {|f| f.exist?}
					SH.logger.info "Skipping #{@dir} since it is already built (use force=true to override)"
					return false
				end
			end
			devtools=@config.devtools
			success=false
			@dir.chdir do
				success=devtools.makechrootpkg(*args, env: @env, **opts)
			end
			self.sign(sign_name: sign) if sign and success
			success
		end

		def add_to_db(db=@config.db)
			SH.logger.warn "Bad database #{db}" unless db.is_a?(DB)
			db.add(*list.select {|l| r=l.exist?; SH.logger.warn "Package #{l} not built, not adding to the db #{db.repo_name}" unless r; r})
		end

		def build(*makepkg_args, mkarchroot: false, chroot: @config[:build_chroot], **opts)
			SH.logger.info "=> Building #{@dir}"
			if chroot
				self.mkarchroot if mkarchroot
				success, _r=makechroot(*makepkg_args, **opts)
			else
				success, _r=make(*makepkg_args, **opts)
			end
			if success and (db=@config.db)
				add_to_db(db)
				if !chroot #sync db
					tools=@config.makepkg_config
					tools.sync_db(db.repo_name)
				end
			end
		end

		def install(*args, view: true, **opts)
			r=get(view: view)
			build(*args, **opts) if r
		end

		def list(**opts)
			call("--packagelist", chomp: :lines, err: "/dev/null", **opts).map {|f| Pathname.new(f)}
		end

		def sign(sign_name: :package, **opts)
			list(**opts).each do |pkg|
				@config.sign(pkg, sign_name: sign_name, **opts) if pkg.file?
			end
		end

	end

	class MakepkgList
		extend CreateHelper
		Archlinux.delegate_h(self, :@l)
		attr_accessor :config, :cache, :l

		def initialize(l, config: Archlinux.config, cache: config.cachedir)
			@config=config
			@cache=Pathname.new(cache)
			@l={}
			l.each do |m|
				unless m.is_a?(Makepkg)
					m=Pathname.new(m)
					m = @cache+m if m.relative?
					m=Makepkg.new(m, config: @config)
				end
				@l[m.name]=m
			end
		end

		def packages(refresh=false, get: false)
			@packages = nil if refresh
			@packages ||= @l.values.reduce(@config.to_packages) do |list, makepkg|
				list.merge(makepkg.packages(get: get))
			end
		end

		def get(*args, view: true, **opts)
			Dir.mktmpdir("aur_view") do |d|
				@l.values.each do |l|
					l.get(*args, logdir: d, view: false, **opts)
				end
				if view
					return @config.view(d)
				else
					return true
				end
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
			@config.devtools.mkarchroot("base-devel")
		end

		def list
			@l.values.flat_map { |l| l.list }
		end

		def add_to_db(db=@config.db)
			SH.logger.warn "Bad database #{db}" unless db.is_a?(DB)
			db.add(*list.select {|l| l.exist?})
		end

		def build(*args, chroot: @config[:build_chroot], **opts)
			mkarchroot if chroot
			@l.values.each do |l|
				l.build(*args, chroot: chroot, **opts)
			end
		end

		def install(*args, view: true, **opts)
			r=get(view: view)
			build(*args, **opts) if r
		end
	end
end
