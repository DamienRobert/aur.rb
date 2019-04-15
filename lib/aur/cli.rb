require 'cmdparse'
require 'aur/version'
require 'simplecolor'
SimpleColor.mix_in_string

module Archlinux
	def self.cli
		parser = CmdParse::CommandParser.new(handle_exceptions: :no_help)
		parser.main_options.program_name = "aur.rb"
		parser.main_options.banner = "Helper to manage aur (Version #{VERSION})"
		parser.main_options.version = VERSION

		parser.global_options do |opt|
			parser.data[:color]=@config.fetch(:color, true)
			SimpleColor.enabled=parser.data[:color]
			opt.on("--[no-]color", "Colorize output", "Default to #{parser.data[:color]}") do |v|
				SimpleColor.enabled=v
			end

			#opt.on("--[no-]db=[dbname]", "Specify database", "Default to #{@config.db}") do |v|
			opt.on("--[no-]db=[dbname]", "Specify database", "Default to #{@config.db}") do |v|
				@config.db=v
			end
		end

		parser.main_options do |opt|
			parser.data[:debug]=@config.fetch(:debug, false)
			parser.data[:loglevel]=@config.fetch(:loglevel, "info")
			opt.on("--debug", "=[level]", "Activate debug informations", "Use `--debug=pry` to launch the pry debugger", "Default to #{parser.data[:debug]}") do |v|
				parser.data[:debug]=v
			end
			opt.on("--log", "=[level]", "Set log level", "Default to #{parser.data[:loglevel]}.") do |v|
				parser.data[:loglevel]=v
			end
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
				cmd.argument_desc(search: "search term")
				cmd.action do |search|
					r=GlobalAurCache.search(search)
					r.each do |pkg|
						name_version="#{pkg["Name"]} (#{pkg["Version"]})"
						SH.logger.info("#{name_version.color(:yellow)}: #{pkg["Description"]}")
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

		parser.add_command('install') do |install_cmd|
			install_cmd.takes_commands(false)
			install_cmd.short_desc("Install packages")
			install_cmd.long_desc(<<-EOS)
Install of update packages
			EOS
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
			install_cmd.argument_desc(packages: "packages names")
			install_cmd.action do |*packages|
				if install_cmd.data[:devel]
					Archlinux.config[:default_install_list_class]=AurMakepkgCache
				end
				aur=Archlinux.config.default_packages
				if install_cmd.data[:check]
					aur.install?(*packages, update: install_cmd.data[:update], rebuild: install_cmd.data[:rebuild])
				else
					aur.install(*packages, update: install_cmd.data[:update], rebuild: install_cmd.data[:rebuild])
				end
			end
		end

		parser.add_command('pacman') do |pacman_cmd|
			pacman_cmd.takes_commands(false)
			pacman_cmd.short_desc("Launch pacman")
			pacman_cmd.long_desc(<<-EOS)
Launch pacman with a custom config file which makes the db accessible.
			EOS
			pacman_cmd.argument_desc(args: "pacman arguments")
			pacman_cmd.action do |*args|
				devtools=Archlinux.config.local_devtools
				devtools.pacman(*args, sudo: @config.sudo)
			end
		end

		parser.add_command('db') do |db_cmd|
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
						#SH.logger.info db.check_update.to_s
						db.check_update do |c|
							db.packages.show_updates(c, obsolete: true)
						end
					else
						db.update
					end
				end
			end
		end

		def parser.parse(*args, &b)
			super(*args) do |lvl, cmd|
				if self.data[:debug]=="pry"
					puts "# Launching pry"
					require 'pry'; binding.pry
				elsif self.data[:debug]
					SH.debug(self.data[:debug])
				end
				b.call(lvl, cmd) if b
			end
		end
		
		parser
	end
end
