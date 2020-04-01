require 'cmdparse'
require 'aur/version'
require 'simplecolor'
SimpleColor.mix_in_string
#SH::Sh.default_sh_options[:log_level_exectue]="debug3" #was debug

module Archlinux
	def self.cli
		parser = CmdParse::CommandParser.new(handle_exceptions: :no_help)
		parser.main_options.program_name = "aur.rb"
		parser.main_options.banner = "Helper to manage aur (Version #{VERSION})"
		parser.main_options.version = VERSION

		parser.global_options do |opt|
			parser.data[:color]=@config.fetch(:color, true)
			parser.data[:debug]=@config.fetch(:debug, false)
			parser.data[:loglevel]=@config.fetch(:loglevel, "info")
			SH.log_options(opt, parser.data)

			#opt.on("--[no-]db=[dbname]", "Specify database", "Default to #{@config.db}") do |v|
			opt.on("--[no-]db=[dbname]", "Specify database", "Default to #{@config.db}") do |v|
				@config.db=v
			end
		end

		add_install_option = ->(cmd) do
			cmd.options do |opt|
				opt.on("-i", "--[no-]install", "Install the package afterwards", "Defaults to #{!! cmd.data[:install]}") do |v|
					cmd.data[:install]=v
				end

				opt.on("--[no-]chroot[=path]", "Use a chroot", "Defaults to #{@config.opts[:chroot][:active] && @config.opts[:chroot][:root]}") do |v|
					if v
						@config.opts[:chroot][:active]=true
						@config.opts[:chroot][:root]=v if v.is_a?(String)
					else
						@config.opts[:chroot][:active]=v
					end
				end

				opt.on("--local", "Local mode", "Shortcut for --no-db --no-chroot") do |v|
					@config.opts[:chroot][:active]=false
					@config.db=false
				end
			end
		end

		parser.main_options do |opt|
			opt.on("--config=config_file", "Set config file") do |v|
				@config=Config.new(v)
			end
		end

		parser.add_command(CmdParse::HelpCommand.new, default: true)
		parser.add_command(CmdParse::VersionCommand.new)

		parser.add_command('aur') do |aur_cmd|
			aur_cmd.add_command('search') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Search aur")
				cmd.long_desc(<<-EOS)
Search aur
				EOS
				cmd.argument_desc(search: "search terms")
				cmd.action do |*search|
					search.each do |s|
						SH.logger.mark(s+":")
						r=GlobalAurCache.search(s)
						r.each do |pkg|
							name_version="#{pkg["Name"]} (#{pkg["Version"]})"
							SH.logger.info("#{name_version.color(:yellow)}: #{pkg["Description"]}")
						end
					end
				end
			end

			aur_cmd.add_command('info') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Info on packages")
				cmd.long_desc(<<-EOS)
Get infos on packages
				EOS
				cmd.argument_desc(packages: "packages names")
				cmd.action do |*packages|
					r=GlobalAurCache.infos(*packages)
					r.each do |pkg|
						name_version="#{pkg["Name"]} (#{pkg["Version"]})"
						SH.logger.info("#{name_version.color(:yellow)}: #{pkg["Description"]}")
					end
				end
			end
		end

		parser.add_command('build') do |build_cmd|
			build_cmd.takes_commands(false)
			build_cmd.short_desc("Build packages")
			build_cmd.long_desc("Build existing PKGBUILD. To download pkgbuild use 'install' instead")
			add_install_option.call(build_cmd)
			build_cmd.action do |*pkgbuild_dirs|
				mkpkg=Archlinux::MakepkgList.new(pkgbuild_dirs, cache: nil)
				mkpkg.build(install: build_cmd.data[:install])
			end
		end

		parser.add_command('install') do |install_cmd|
			install_cmd.takes_commands(false)
			install_cmd.short_desc("Install packages")
			install_cmd.long_desc(<<-EOS)
Install of update packages
			EOS
			install_cmd.data={install: true}
			add_install_option.call(install_cmd)
			install_cmd.options do |opt|
				opt.on("-u", "--[no-]update", "Update existing packages too") do |v|
					install_cmd.data[:update]=v
				end
			end
			install_cmd.options do |opt|
				opt.on("-c", "--[no-]check", "Only check updates/install") do |v|
					install_cmd.data[:check]=v
				end
			end
			install_cmd.options do |opt|
				opt.on("--[no-]rebuild=[mode]", "Rebuild given packages", "with --rebuild=full also rebuild their deps") do |v|
					install_cmd.data[:rebuild]=v
				end
			end
			install_cmd.options do |opt|
				opt.on("--[no-]devel", "Also check/update devel packages") do |v|
					install_cmd.data[:devel]=v
				end
			end
			install_cmd.options do |opt|
				opt.on("--[no-]obsolete", "Also show obsolete packages", "Not that you will get false obsolete packages unless you specifically upgrade everything") do |v|
					install_cmd.data[:obsolete]=v
				end
			end
			install_cmd.argument_desc(packages: "packages names")
			install_cmd.action do |*packages|
				if install_cmd.data[:devel]
					Archlinux.config[:default_install_list_class]=AurMakepkgCache
				end
				aur=Archlinux.config.default_packages
				opts={update: install_cmd.data[:update], rebuild: install_cmd.data[:rebuild]}
				opts[:no_show]=[] if install_cmd.data[:obsolete]
				if install_cmd.data[:check]
					aur.install?(*packages, **opts)
				else
					opts[:install]=install_cmd.data[:install]
					aur.install(*packages, **opts)
				end
			end
		end

		%w(pacman makepkg nspawn mkarchroot makechrootpkg).each do |cmd|
			parser.add_command(cmd) do |devtools_cmd|
				devtools_cmd.takes_commands(false)
				devtools_cmd.short_desc("Launch #{cmd}")
				case cmd
				when "pacman"
					devtools_cmd.long_desc(<<-EOS)
Launch pacman with a custom config file which makes the db accessible.
					EOS
				end
				devtools_cmd.argument_desc(args: "#{cmd} arguments")
				devtools_cmd.action do |*args|
					devtools=Archlinux.config.local_devtools
					devtools.public_send(cmd,*args, sudo: @config.sudo)
				end
			end
		end

		parser.add_command('db') do |db_cmd|
			db_cmd.add_command('list') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("List the content of the db")
				cmd.options do |opt|
					opt.on("-v", "--[no-]version", "Add the package version") do |v|
						cmd.data[:version]=v
					end
					opt.on("-q", "--quiet", "Machine mode") do |v|
						cmd.data[:quiet]=v
					end
				end
				cmd.action do ||
					db=Archlinux.config.db
					if cmd.data[:quiet]
						pkgs=db.packages
						l= cmd.data[:version] ? pkgs.keys.sort : pkgs.names.sort
						SH.logger.info l.join(' ')
					else
						SH.logger.mark "#{db.file}:"
						db.packages.list(cmd.data[:version])
					end
				end
			end

			db_cmd.add_command('update') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Update the db")
				cmd.long_desc(<<-EOS)
Update the db according to the packages present in its folder
				EOS
				cmd.options do |opt|
					opt.on("-c", "--[no-]check", "Only check updates") do |v|
						cmd.data[:check]=v
					end
				end
				cmd.action do ||
					db=Archlinux.config.db
					if cmd.data[:check]
						db.show_updates
					else
						db.update
					end
				end
			end

			db_cmd.add_command('add') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Add files to the db")
				cmd.options do |opt|
					opt.on("-f", "--[no-]force", "Force adding files that are older than the ones in the db") do |v|
						cmd.data[:force]=v
					end
					opt.on("--[no-]force-sign", "Force resigning the packages in the db, even if there is already a signature") do |v|
						cmd.data[:force_sign]=v
					end
				end
				cmd.action do |*files|
					db=Archlinux.config.db
					db.add_to_db(files, update: !cmd.data[:force], force_sign: cmd.data[:force_sign])
				end
			end

			db_cmd.add_command('rm') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Remove packages from db")
				cmd.options do |opt|
					opt.on("-f", "--[no-]force", "Also remove the package themselves") do |v|
						cmd.data[:force]=v
					end
				end
				cmd.action do |*files|
					db=Archlinux.config.db
					if cmd.data[:force]
						db.rm_from_db(*files)
					else
						db.remove(*files)
					end
				end
			end

			db_cmd.add_command('clean') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Clean old files in the db repository")
				cmd.options do |opt|
					opt.on("-f", "--[no-]force", "Force clean (default to dry-run)") do |v|
						cmd.data[:force]=v
					end
				end
				cmd.action do ||
					db=Archlinux.config.db
					paths=db.clean(dry_run: !cmd.data[:force])
					if cmd.data[:force]
						SH.logger.mark "Cleaned:"
					else
						SH.logger.mark "To clean:"
					end
					SH.logger.info paths.map {|p| "- #{p}"}.join("\n")
				end
			end
		end

		parser.add_command('pkgs') do |pkgs_cmd|
			pkgs_cmd.add_command('list') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("List packages")
				cmd.long_desc("The listed package can be '@db' (the current db), '@dbdir' (the packages in the db directory), ':core' (a pacman repo name), :local (the local repo), a file (/var/cache/pacman/pkg/linux-5.3.13.1-1-x86_64.pkg.tar.xz) or a package dir (/var/cache/pacman/pkg); @get(foo1,foo2) (query the aur), @rget(foo1,foo2) (recursively query the aur); db@[r]get (query our db) ")
				cmd.options do |opt|
					opt.on("-v", "--[no-]version", "Add the package version") do |v|
						cmd.data[:version]=v
					end
				end
				cmd.action do |*repos|
					pkgs=PackageClass.packages(*repos)
					pkgs.list(cmd.data[:version])
				end
			end

			pkgs_cmd.add_command('graph') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("List packages dependencies as a graph")
				cmd.action do |*repos|
					pkgs=PackageClass.packages(*repos)
					puts pkgs.graph.dump
				end
			end

			pkgs_cmd.add_command('compare') do |cmd|
				cmd.takes_commands(false)
				cmd.short_desc("Compare packages")
				cmd.long_desc(<<-EOS)
					Use '--' to separate the two lists
					Exemple: `compare @db -- @dbdir` is essentially the same as `db update -c`
					Exemple: `compare @db -- @get(yay)` is like checking for a yay update
				EOS
				cmd.action do |*repos|
					pkg1, pkg2 = PackageClass.packages_list(*repos)
					pkg1.get_updates(pkg2)
				end
			end
		end

		parser.add_command('sign') do |cmd|
			cmd.takes_commands(false)
			cmd.short_desc("Sign files")
			cmd.options do |opt|
				opt.on("-f", "--[no-]force", "Overwrite existing signatures") do |v|
					cmd.data[:force]=v
				end
				opt.on("-v", "--verify", "Verify signatures") do |v|
					cmd.data[:verify]=v
				end
			end
			cmd.action do |*files|
				if cmd.data[:verify]
					Archlinux.config.verify_sign(*files)
				else
					Archlinux.config.sign(*files, force: cmd.data[:force])
				end
			end
		end

		def parser.parse(*args, &b)
			super(*args) do |lvl, cmd|
				SH.process_log_options(self.data)
				b.call(lvl, cmd) if b
			end
		end

		@config.parser(parser)
		
		parser
	end
end
