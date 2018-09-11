require 'aur/helpers'

module Archlinux

	class Config
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :opts
		Archlinux.delegate_h(self, :@opts)
		include SH::ShConfig

		def initialize(file, **opts)
			file=Pathname.new(file)
			file=Pathname.new(ENV["XDG_CONFIG_HOME"] || "#{ENV['HOME']}/.config") + file if file.relative?
			file_config= file.readable? ? file.read : '{}'
			wrap=eval("Proc.new { |context| #{file_config} }")
			@opts=default_config.merge(opts)
			user_conf=wrap.call(self)
			@opts.merge!(user_conf) if user_conf.is_a?(Hash)
			run_sudo_loop if dig(:sudo_loop, :active)
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
				},
				packages: :AurPackageList,
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
				sh_config: { #default programs options
					makepkg: {default_opts: ["-crs", "--needed"]},
					makechrootpkg: {default_opts: ["-cu"]},
				},
				view: "vifm -c view! -c tree -c 0",
				git: {
					update: "git pull",
					clone: "git clone",
				},
				sudo_loop: {
					command: "sudo -v",
					interval: 30,
					active: false,
				}
			}
		end

		def get_config_file(name, type: :default)
			dig(:config_files, type, name) || dig(:config_files, :default, name)
		end

		#:makepkg, :makechrootpkg, :repo (=repo-add, repo-remove)
		def sign(mode)
			opt_sign=@opts[:sign]
			if opt_sign.is_a?(Hash)
				opt_sign[mode]
			else
				opt_sign
			end
		end

		def view(dir)
			view=@opts[:view]
			SH.sh_or_proc(view, dir)
		end

		def git_update
			method=@opts[:git][:update]
			SH.sh_or_proc(method)
		end

		def git_clone(url, dir)
			method=@opts[:git][:clone]
			SH.sh_or_proc(method, url, dir)
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
				@db=DB.new(name)
			when String
				if DB.db_file?(name)
					@db=DB.new(name)
				else
					@db=DB.new(cachedir+".db"+"#{name}.db.tar.gz")
				end
			when true
				@db=DB.new(cachedir+".db"+"aur.db.tar.gz")
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
				sudo.extend(SH::SudoLoop.config(**opts))
			end
			sudo
		end

		def to_packages(l=[])
			Archlinux.const_get(@opts[:packages]).new(l)
		end
	end

	self.singleton_class.attr_accessor :config
	@config=Config.new("aur.rb")

end
