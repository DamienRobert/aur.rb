require 'aur/config'

module Archlinux
	class PacmanConf
		def self.create(v, config: Archlinux.config)
			v.is_a?(self) ? v : self.new(v, config: config) #pass empty keywords so that a Hash is seen as an argument and not a list of keywords
		end

		Archlinux.delegate_h(self, :@pacman_conf)
		attr_accessor :pacman_conf, :config

		def initialize(conf="/etc/pacman.conf", config: Archlinux.config, **keys)
			@config=config
			if conf.is_a?(String) or conf.is_a?(Pathname)
				conf=parse(conf, **keys)
			end
			@pacman_conf=conf
		end

		def self.parse(content)
			list=%i(HoldPkg IgnorePkg IgnoreGroup NoUpgrade NoExtract SigLevel LocalFileSigLevel RemoteFileSigLevel Usage Server)
			mode=:options
			config={options: {}, repos: {}}
			content=content.each_line if content.is_a?(String)
			content.each do |l|
				if (m=l.match(/^\[([\w-]+)\]$/))
					mode=m[1]
					if mode == "options"
						mode=:options 
					else
						config[:repos][mode]||={}
					end
				else
					key, value=l.split(' = ', 2)
					key=key.to_sym
					h =  mode==:options ? config[:options] : config[:repos][mode]
					if list.include?(key)
						h[key]||=[]
						h[key]<<value
					else
						h[key]=value
					end
				end
			end
			config
		end

		def parse(file, raw: false, args: nil)
			unless args
				if raw
					args=[:'pacconf', "--raw", "--config=#{file}"]
				else
					args=[:'pacman-conf', "--config=#{file}"]
				end
			end
			output=@config.launch(*args) do |*args|
				SH.run_simple(*args, chomp: :lines)
			end
			self.class.parse(output)
		end

		def non_official_repos
			repos=@pacman_conf[:repos]
			repos.slice(*(repos.keys - %w(core extra community multilib testing community-testing multilib-testing)))
		end

		def to_s
			r=[]
			print_values=lambda do |h, section|
				r<<"[#{section}]" if section
				h.each do |k,v|
					case v
					when nil
						r << k
					when Array
						v.each { |vv| r << "#{k} = #{vv}" }
					else
						r << "#{k} = #{v}"
					end
				end
			end
			print_values.call(@pacman_conf[:options], "options")
			@pacman_conf[:repos].each do |section, props|
				print_values.call(props, section)
			end
			r.join("\n")+"\n"
		end

		def tempfile
			SH::VirtualFile.new("pacman.conf", to_s)
		end
	end

	class Devtools
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end
		Archlinux.delegate_h(self, :@opts)

		attr_accessor :config, :opts
		def initialize(config: Archlinux.config, **opts)
			@config=config
			@opts=@config.opts.merge(opts)
			# %i(pacman_conf makepkg_conf).each do |key|
			# 	@opts[key]=@opts[key].tempfile.file if @opts[key].respond_to?(:tempfile)
			# end
			root=@opts.dig(:chroot, :root) and @opts[:chroot][:root]=Pathname.new(root)
			add_binds
		end

		def add_binds
			require 'uri'
			if (conf=@opts[:pacman_conf]).is_a?(PacmanConf)
				conf[:repos].each do |_name, opts|
					opts[:Server].each do |server|
						server.match(%r!file://(.*)!) do |m|
							@opts[:bind_ro]||=[]
							@opts[:bind_ro] << URI.unescape(m[1])
						end
					end
				end
			end
		end

		def files
			%i(pacman_conf makepkg_conf).each do |key|
				if @opts[key]
					file=@opts[key]
					file=file.tempfile.file if file.respond_to?(:tempfile)
					yield key, file
				end
			end
		end

		def pacman_config
			Pacman.create(@opts[:pacman_conf])
		end

		def pacman(*args, default_opts: [], **opts, &b)
			files do |key, file|
				default_opts += ["--config", file] if key==:pacman_conf
			end
			opts[:method]||=:sh
			@config.launch(:pacman, *args, default_opts: default_opts, **opts, &b)
		end

		def makepkg(*args, run: :sh, default_opts: [], **opts, &b)
			files do |key, file|
				# trick to pass options to pacman
				args << "PACMAN_OPTS+=--config=#{file.shellescape}"
				default_opts += ["--config", file] if key==:makepkg_conf
			end
			opts[:method]||=run
			@config.launch(:makepkg, *args, default_opts: default_opts, **opts, &b)
		end


		def nspawn(*args, root: @opts.dig(:chroot,:root)+'root', default_opts: [], **opts, &b)
			files do |key, file|
				default_opts += ["-C", file] if key==:pacman_conf
				default_opts += ["-M", file] if key==:makepkg_conf
			end
			if (binds_ro=@opts[:bind_ro])
				binds_ro.each do |b|
					args.unshift("--bind-ro=#{b}")
				end
			end
			if (binds_rw=@opts[:bind_rw])
				binds_rw.each do |b|
					args.unshift("--bind=#{b}")
				end
			end
			args.unshift root

			opts[:method]||=:sh
			@config.launch(:'arch-nspawn', *args, default_opts: default_opts, **opts, &b)
		end

		# this takes the same options as nspawn
		def mkarchroot(*args, nspawn: @opts.dig(:chroot, :update), default_opts: [], root: @opts.dig(:chroot, :root), **opts, &b)
			files do |key, file|
				default_opts += ["-C", file] if key==:pacman_conf
				default_opts += ["-M", file] if key==:makepkg_conf
			end
			root.sudo_mkpath unless root.directory?
			root=root+'root'
			opts[:method]||=:sh
			if (root+'.arch-chroot').file?
				# Note that if nspawn is not called (and the chroot does not
				# exist), then the passed pacman.conf will not be replace the one
				# in the chroot. And when makechrootpkg calls nspawn, it does not
				# transmit the -C/-M options. So even if we don't want to update,
				# we should call a dummy bin like 'true'
				if nspawn
					return nspawn.call(root) if nspawn.is_a?(Proc)
					nspawn=nspawn.shellsplit if nspawn.is_a?(String)
					self.nspawn(*nspawn, root: root, **opts, &b)
				end
			else
				@config.launch(:mkarchroot, root, *args, default_opts: default_opts, sudo: @config.sudo, **opts,&b)
			end
		end

		def makechrootpkg(*args, default_opts: [], **opts, &b)
			default_opts+=['-r', @opts.dig(:chroot, :root)]
			if (binds_ro=@opts[:bind_ro])
				binds_ro.each do |b|
					default_opts += ["-D", b]
				end
			end
			if (binds_rw=@opts[:bind_rw])
				binds_rw.each do |b|
					default_opts += ["-d", b]
				end
			end
			opts[:method]||=:sh

			#makechrootpkg calls itself with sudo --preserve-env=SOURCE_DATE_EPOCH,GNUPGHOME so it does not keep PKGDEST..., work around this by providing our own sudo
			@config.launch(:makechrootpkg, *args, default_opts: default_opts, sudo: @config.sudo('sudo --preserve-env=GNUPGHOME,PKGDEST,SOURCE_DATE_EPOCH'), **opts, &b)
		end

		def tmp_pacman(conf, **opts)
			PacmanConf.create(conf).tempfile.create(true) do |file|
				pacman=lambda do |*args, **pac_opts, &b|
					pac_opts[:method]||=:sh
					@config.launch(:pacman, *args, default_opts: ["--config", file], **opts.merge(pac_opts), &b)
				end
				yield pacman, file
			end
		end

		def sync_db(*names, install: [], **pacman_opts)
			conf=PacmanConf.create(@opts[:pacman_conf])
			new_conf={options: conf[:options], repos: {}}
			repos=conf[:repos]
			names.each do |name|
				if repos[name]
					new_conf[:repos][name]=repos[name]
				else
					SH.logger.cli_warn "sync_db: unknown repo #{name}"
				end
			end
			tmp_pacman(new_conf) do |pacman, file|
				if block_given?
					return yield(pacman, file)
				else
					args=['-Syu']
					args+=install
					return pacman[*args, sudo: @config.sudo, **pacman_opts]
				end
			end
		end

	end
end
