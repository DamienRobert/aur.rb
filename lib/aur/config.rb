require 'aur/helpers'
require 'aur/packages'
require 'aur/makepkg'

module Archlinux

	class Config
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :opts
		Archlinux.delegate_h(self, :@opts)
		include SH::ShConfig

		# pass nil to prevent loading a config file
		def initialize(file="aur.rb", **opts)
			if file
				file=Pathname.new(file)
				file=Pathname.new(ENV["XDG_CONFIG_HOME"] || "#{ENV['HOME']}/.config") + file if file.relative?
			end
			file_config= file&.readable? ? file.read : '{}'
			wrap=eval("Proc.new { |config| #{file_config} }")
			@opts=default_config.deep_merge(opts)
			user_conf=wrap.call(self)
			@opts.deep_merge!(user_conf) if user_conf.is_a?(Hash)
		end

		def sh_config
			@opts[:sh_config]
		end

		def default_config
			{
				cache: "arch_aur", #where we dl PKGBUILDs
				db: 'aur', #if relative the db will be in cachedir
				aur_url: "https://aur.archlinux.org/", #base aur url
				chroot: {
					root: "/var/lib/aurbuild/x86_64", #chroot root
					active: false, #do we use the chroot?
					update: 'pacman -Syu --noconfirm', #how to update an existing chroot
					packages: ['base-devel'], #the packages that are installed in the chroto
				},
				default_packages_class: AurPackageList,
				default_install_list_class: AurMakepkgCache,
				default_get_class: Git, #we use git to fetch PKGBUILD from aur
				sign: true, #can be made more atomic, cf the sign method
				config_files: {
					default: {
						pacman: "/etc/pacman.conf", #default pacman-conf
					},
					chroot: {
						pacman: "/usr/share/devtools/pacman-extra.conf", #pacman.conf for chroot build
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
		def default_packages
			db.packages.merge(RepoPkgs.new(Repo.foreign_list, config: self).packages)
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

		def setup_pacman_conf(conf)
			pacman=PacmanConf.create(conf, config: self)
			aur=self.db(false)
			if aur and !pacman[:repos].include?(aur.repo_name)
				pacman[:repos][aur.repo_name]={Server: ["file://#{URI.escape(aur.dir.to_s)}"]}
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

		def devtools
			unless @devtools_config
				require 'uri'
				# here we need the raw value, since this will be used by pacstrap
				# which calls pacman --root; so the inferred path for DBPath and so
				# on would not be correct since it is specified
				devtools_pacman=PacmanConf.new(get_config_file(:pacman, type: :chroot))
				# here we need to expand the config, so that Server =
				# file://...$repo...$arch get their real values
				my_pacman=default_pacman_conf
				devtools_pacman[:repos].merge!(my_pacman.non_official_repos)
				setup_pacman_conf(devtools_pacman)
				@devtools_config = Devtools.new(pacman_conf: devtools_pacman, config: self)
			end
			@devtools_config
		end

		def makepkg_config
			unless @makepkg_config
				makepkg_pacman=get_config_file(:pacman, type: :local)
				setup_pacman_conf(makepkg_pacman)
				@makepkg_config = Devtools.new(pacman_conf: makepkg_pacman, config: self)
			end
			@makepkg_config
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
				SH.logger.warn("Database name #{name} not suitable")
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

		def sudo(arg=true)
			sudo=arg
			if dig(:sudo_loop, :active)
				opts=dig(:sudo_loop).clone
				opts.delete(:active)
				sudo.extend(SH::SudoLoop.configure(**opts))
			end
			sudo
		end

		def stop_sudo_loop
			sudo=self.sudo
			sudo&.stop_sudo_loop if sudo&.respond_to?(:stop_sudo_loop)
		end

		def to_packages(l=[])
			klass=@opts[:default_packages_class]
			klass=Archlinux.const_get(klass) if klass.is_a?(Symbol)
			klass.new(l)
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

		# return the files that were signed
		def sign(*files, sign_name: nil, force: false)
			sign_name=use_sign?(sign_name) if sign_name.is_a?(Symbol)
			files.map do |file|
				sig="#{file}.sig"
				if !Pathname.new(file).file?
					SH.logger.error "Invalid file to sign #{file}"
					next
				end
				if !force and Pathname.new(sig).file?
					SH.logger.debug "Signature #{sig} already exits, skipping"
					next
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
			@install_list ||= @opts[:default_install_list_class].new(config: self)
		end
	end

	self.singleton_class.attr_accessor :config
	@config ||= Config.new("aur.rb")
end
