require 'aur/config'
require 'aur/devtools'
require 'aur/packages'

module Archlinux
	class Makepkg
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :dir, :base, :env, :config, :asdeps

		def initialize(dir, config: Archlinux.config, env: {}, asdeps: false)
			@dir=DR::Pathname.new(dir)
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

		def call(*args, run: :run_simple, **opts)
			@config.launch(:makepkg, *args, **opts) do |*args, **opts|
				@dir.chdir do
					SH.public_send(run, @env, *args, **opts)
				end
			end
		end

		def info
			stdin=call("--printsrcinfo", chomp: :lines)
			mode=nil; r={}; current={}; pkgbase=nil; pkgname=nil
			stdin.each do |l|
				key, value=l.split(/\s*=\s*/,2)
				next if key.nil?
				if key=="pkgbase"
					mode=:pkgbase; current[:pkgbase]=value
				elsif key=="pkgname"
					if mode==:pkgbase
						r=current
						r[:pkgs]={repo: @dir}
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

		def packages(refresh=false)
			@packages=nil if refresh
			unless @packages
				r=info
				pkgs=r.delete(:pkgs)
				r[:pkgbase]
				base=Package.new(r)
				list=pkgs.map do |name, pkg|
					pkg[:name]=name
					Package.new(pkg).merge(base)
				end
				@packages=PackageList.new(list)
			end
			@packages
		end

		def url
			@config[:aur_url]+@base.to_s+".git"
		end

		def get(logdir: nil, view: false)
			#SH.sh("vcs clone_or_update --diff #{url.shellescape} #{@dir.shellescape}")
			if logdir
				logdir=DR::Pathname.new(logdir)
				logdir.mkpath
			end
			if @dir.exist?
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
			else
				unless @config.git_clone(url, @dir)
					SH.logger.error("Error in cloning #{url} to #{@dir}")
				end
				SH.sh("git clone #{url.shellescape} #{@dir.shellescape}")
				if logdir
					(logdir+"!#{@dir.basename}").on_ln_s(@dir.realpath)
				end
			end
			if view
				return @config.view(@dir)
			else
				return true
			end
		end

		# raw call to makepkg
		def makepkg(*args, **opts)
			call(*args, run: :sh, **opts)
		end

		def make(*args, sign: config.sign(:makepkg), default_opts: [], force: false, asdeps: @asdeps, **opts)
			default_opts << "--sign" if sign
			default_opts << "--key=#{sign}" if sign.is_a?(String)
			default_opts << "--force" if force
			default_opts << "--asdeps" if asdeps

			tools=@config.makepkg_config #this set up pacman and makepkg config files
			success=false
			@dir.chdir do
				success=tools.makepkg(*args, default_opts: default_opts, env: @env, **opts)
			end
			success
		end

		def mkarchroot
			@config.devtools.mkarchroot("base-devel")
		end

		def makechroot(*args, sign: @config.sign(:makechrootpkg), force: false, **opts)
			unless force
				if list.all? {|f| f.exist?}
					SH.logger.info "Skipping #{@dir} since it is already built (use force=trye to override)"
					return false
				end
			end
			devtools=@config.devtools
			success=false
			@dir.chdir do
				success=devtools.makechrootpkg(*args, env: @env, **opts)
			end
			self.sign(sign) if sign and success
			success
		end

		def add_to_db(db=@config.db)
			SH.logger.warn "Bad database #{db}" unless db.is_a?(DB)
			db.add(*list.select {|l| l.exist?})
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

		def sign(sign, **opts)
			list(**opts).each do |pkg|
				if pkg.file?
					if (sig=Pathname.new("#{pkg}.sig")).file?
						SH.logger.warn "Signature #{sig} already exits, skipping"
					else
						SH.sh("gpg #{sign.is_a?(String) ? "-u #{sign}" : ""} --detach-sign --no-armor #{pkg.shellescape}") 
					end
				end
			end
		end

	end

	class MakepkgList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

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
					v=Makepkg.new(m, config: @config)
					@l[v.name]=v
				end
			end
		end

		def packages(refresh=false)
			@packages = nil if refresh
			@packages ||= @l.values.reduce do |list, makepkg|
				list.merge(makepkg.packages)
			end
		end

		def get(*args, view: true)
			Dir.mktmpdir("aur_view") do |d|
				@l.values.each do |l|
					l.get(*args, logdir: d)
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
