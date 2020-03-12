require 'aur/helpers'
require 'aur/packages'
require 'aur/install_packages'
require 'aur/makepkg'

module Archlinux

	class Config
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :opts
		Archlinux.delegate_h(self, :@opts)
		include SH::ShConfig
		include DR::PPHelper

		# pass nil to prevent loading a config file
		def initialize(file="aur.rb", **opts)
			@file=file
			if file
				file=Pathname.new(file)
				file=Pathname.new(ENV["XDG_CONFIG_HOME"] || "#{ENV['HOME']}/.config") + file if file.relative?
			end
			file_config= file&.readable? ? file.read : (SH.logger.error "Error: Config file '#{file}' unreadable" unless file.nil?; '{}')
			wrap=eval("Proc.new { |config| #{file_config} }")
			@opts=default_config.deep_merge(opts)
			user_conf=wrap.call(self)
			@opts.deep_merge!(user_conf) if user_conf.is_a?(Hash)
		end

		def to_pp
			@file.to_s
		end

		def sh_config
			@opts[:sh_config]
		end

		def default_config
			{
				cache: "arch_aur", #where we dl PKGBUILDs; if relative will be in XDG_CACHE_HOME
				db: 'aur', #if relative the db will be in cache dir
				aur_url: "https://aur.archlinux.org/", #base aur url
				chroot: {
					root: "/var/lib/aurbuild/x86_64", #chroot root
					active: false, #do we use the chroot?
					update: 'pacman -Syu --noconfirm', #how to update an existing chroot
					packages: ['base-devel'], #the packages that are installed in the chroto
					# It can make sense to add %w(python ruby nodejs go-pie rust git)...
				},
				default_packages_class: PackageList,
				# default_install_list_class: AurMakepkgCache,
				default_install_packages_class: AurPackageList,
				default_install_list_class: AurCache,
				default_get_class: Git, #we use git to fetch PKGBUILD from aur
				sign: true, #can be made more atomic, cf the sign method
				config_files: {
					default: {
						pacman: "/etc/pacman.conf", #default pacman-conf
						makepkg: "/etc/makepkg.conf",
					},
					chroot: {
						pacman: "/usr/share/devtools/pacman-extra.conf", #pacman.conf for chroot build
						makepkg: "/usr/share/devtools/makepkg-x86_64.conf",
					},
					local: {
						pacman: "/etc/pacman.conf", # pacman-conf for local makepkg build
					},
				},
				sh_config: { #default programs options, called each time
					makepkg: {default_opts: []},
					makechrootpkg: {default_opts: ["-cu"]},
					# So on fist thought, we do not need -u since we update 'root' before ourselves; but if we build several packages we may need the previous ones in the db, and since we only update 'root' once, they won't be available on 'copy'; so we still need '-u'
				},
				makepkg: {
					build_args: ["-crs", "--needed"], #only used when building
				},
				view: "vifm -c view! -c tree -c 0", #can also be a Proc
				sudo_loop: {
					command: "sudo -v",
					interval: 30,
					active: true,
				}
			}
		end

		# packages to check
		def default_packages(use_db: db != false, use_foreign: true)
			if @default_packages.nil?
				# by default this is the db packages + foreign packages
				default=use_db ? db.packages : to_packages([]) 
				default.merge(RepoPkgs.new(Repo.foreign_list, config: self).packages) if use_foreign
				default=yield default if block_given?
				@default_packages=to_packages(default.l, install: true)
			else
				@default_packages
			end
		end

		def get_config_file(name, type: :default)
			dig(:config_files, type, name) || dig(:config_files, :default, name)
		end

		def view(dir)
			view=@opts[:view]
			SH.sh_or_proc(view, dir)
		end

		def cachedir
			global_cache=Pathname.new(ENV["XDG_CACHE_HOME"] || "#{ENV['HOME']}/.cache")
			cache=global_cache+@opts[:cache]
			cache.mkpath
			cache
		end

		# add our default db to the list of repos
		private def setup_pacman_conf(conf)
			pacman=PacmanConf.create(conf, config: self)
			aur=self.db(false)
			if aur and !pacman[:repos].include?(aur.repo_name)
				require 'uri'
				pacman[:repos][aur.repo_name]={Server: ["file://#{DR::URIEscape.escape(aur.dir.to_s)}"]}
			end
			pacman
		end

		def default_pacman_conf
			@default_pacman_conf ||= if (conf=get_config_file(:pacman))
				PacmanConf.new(conf, config: self)
			else
				PacmanConf.new(config: self)
			end
		end

		def chroot_devtools
			unless @chroot_devtools
				devtools_pacman=PacmanConf.new(get_config_file(:pacman, type: :chroot))
				makepkg_conf=get_config_file(:makepkg, type: :chroot)
				my_pacman=default_pacman_conf
				devtools_pacman[:repos].merge!(my_pacman.non_official_repos)
				devtools_pacman=setup_pacman_conf(devtools_pacman)
				@chroot_devtools = Devtools.new(pacman_conf: devtools_pacman, makepkg_conf: makepkg_conf, config: self)
			end
			@chroot_devtools
		end

		def local_devtools
			unless @local_devtools
				makepkg_pacman=get_config_file(:pacman, type: :local)
				makepkg_conf=get_config_file(:makepkg, type: :local)
				makepkg_pacman=setup_pacman_conf(makepkg_pacman)
				@local_devtools = Devtools.new(pacman_conf: makepkg_pacman, makepkg_conf: makepkg_conf, config: self)
			end
			@local_devtools
		end

		def db=(name)
			case name
			when DB
				@db=name
			when Pathname
				@db=DB.new(name, config: self)
			when String
				if DB.db_file?(name)
					@db=DB.new(name, config: self)
				else
					@db=DB.new(cachedir+".db"+"#{name}.db.tar.gz", config: self)
				end
			when true
				@db=DB.new(cachedir+".db"+"aur.db.tar.gz", config: self)
			when false, nil
				@db=name #false for false, nil to reset
			else
				SH.logger.warn("Database name #{name} not suitable, fallback to default")
				@db=nil
			end
			# reset these so the pacman_conf gets the correct db name
			@makepkg_config=nil
			@devtools_config=nil
		end

		def db(create=true)
			@db.nil? and self.db=@opts[:db]
			if create and @db
				@db.create
			end
			@db
		end

		# if changing a setting, we may need to reset the rest
		def reset
			self.db=nil
		end

		# note: since 'true' is frozen, we cannot extend it and keep a
		# @sudo_loop_thread. Moreover we only want one sudo loop active, so we
		# will call it ourselves
		def sudo(arg=true)
			if dig(:sudo_loop, :active)
				opts=dig(:sudo_loop).clone
				opts.delete(:active)
				self.extend(SH::SudoLoop.configure(**opts))
				self.sudo_loop
			end
			arg
		end

		def stop_sudo_loop
			stop_sudo_loop if respond_to?(:stop_sudo_loop)
		end

		def to_packages(l=[], install: false)
			Archlinux.create_class(
				install ? @opts[:default_install_packages_class] :
				@opts[:default_packages_class],
				l, config: self)
		end

		#:package, :db
		def use_sign?(mode)
			opt_sign=@opts[:sign]
			if opt_sign.is_a?(Hash)
				opt_sign[mode]
			else
				opt_sign
			end
		end

		# output a list of sign names, or [] if we want to sign with the default sign name, false if we don't
		def sign_names
			opt_sign=@opts[:sign]
			signs=if opt_sign.is_a?(Hash)
					opt_sign.values
				else
					[*opt_sign]
				end
			names=signs.select {|s| s.is_a?(String)}
			names = false if names.empty? and ! signs.any?
			return names
		end

		# return the files that were signed
		def sign(*files, sign_name: nil, force: false)
			sign_name=use_sign?(sign_name) if sign_name.is_a?(Symbol)
			files.map do |file|
				sig="#{file}.sig"
				if !Pathname.new(file).file?
					SH.logger.error "Invalid file to sign #{file}"
					next
				end
				if Pathname.new(sig).file?
					if force
						SH.logger.verbose2 "Signature #{sig} already exits, overwriting"
					else
						SH.logger.verbose2 "Signature #{sig} already exits, skipping"
						next
					end
				end
				args=['--detach-sign', '--no-armor']
				args+=['-u', sign_name] if sign_name.is_a?(String)
				launch(:gpg, *args, file) do |*args|
					suc, _r=SH.sh(*args)
					suc ? file : nil
				end
			end.compact
		end

		def verify_sign(*files)
			args=['--verify']
			files.map do |file|
				file="#{file}.sig" unless file.to_s =~ /(.sig|.asc)/
				launch(:gpg, *args, file) do |*args|
					suc, _r=SH.sh(*args)
					[file, suc]
				end
			end.to_h
		end

		def install_list
			@install_list ||= Archlinux.create_class(@opts[:default_install_list_class], config: self)
		end

		def pre_install(*_args, **_opts)
			names=sign_names
			if names
				cargs=["--detach-sign", "-o", "/dev/null", "/dev/null"]
				if names.empty?
					launch(:gpg, *cargs, method: :sh)
				else
					args=names.map { |name| ['-u', name] }.flatten+cargs
					launch(:gpg, *args, method: :sh)
				end
			end
		end

		def post_install(pkgs, install: false, **opts)
			if (db=self.db)
				if install
					tools=local_devtools
					# info=opts[:pkgs_info]
					# to_install=info[:all_pkgs].select {|_k,v| v[:op]==:install}.
					# 	map {|_k,v| v[:out_pkg]}
					# tools.sync_db(db.repo_name, install: to_install)

					# Let's just install anything and let pacman handle it
					m=opts[:makepkg_list]
					if m
						# we need to update the package versions with the ones
						# provided by the current makepkg (which may be more recent than
						# the one from aur's rpc in case of devel packages)
						ipkgs=pkgs.map do |pkg|
							found=m.packages.find(Query.strip(pkg))
							found || pkg
						end
					else
						ipkgs=pkgs
					end
					tools.sync_db(db.repo_name, install: %w(--needed) + ipkgs)
				end
			end
		end

		def parser(parser) #to add cli options in the config file
		end
	end

	self.singleton_class.send :attr_accessor, :config
	@config ||= Config.new("aur.rb")
end
