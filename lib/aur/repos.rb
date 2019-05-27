require 'aur/helpers'
require 'aur/packages'
require 'time'

module Archlinux
	# this hold a repo name
	class Repo
		extend CreateHelper

		attr_accessor :repo, :config
		def initialize(name, config: Archlinux.config)
			@repo=name
			@config=config
		end

		def list(mode: :pacsift)
			command= case mode
			when :pacman, :name
				if @repo=="local"
					"pacman -Qq"
				else
					"pacman -Slq #{@repo.shellescape}" #returns pkg
				end
			when :repo_name
				#like pacsift, but using pacman
				list(mode: :name).map {|i| @repo+"/"+i}
			when :pacsift
				#this mode is prefered, so that if the same pkg is in different
				#repo, than pacman_info returns the correct info
				#pacsift understand the 'local' repo
				"pacsift --exact --repo=#{@repo.shellescape} <&-" #returns repo/pkg
			when :paclist, :name_version
				#cannot show the local repo; we could use `expac -Q '%n %v' but we
				#don't use this mode anyway
				"paclist #{@repo.shellescape}" #returns 'pkg version'
			end
			SH.run_simple(command, chomp: :lines) {return nil}
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages ||= @config.to_packages(self.class.info(*list))
		end

		def self.pacman_info(*pkgs, local: false) #local=true refers to the local db info. Note that pacman does not understand local/pkg but pacinfo does
			list=[]
			to_list=lambda do |s|
				return [] if s=="None"
				s.split
			end
			# Note: core/pacman only works for -Sddp or -Si, not for -Qi
			# Indeed local/pacman works for pacinfo, but not for pacman (needs
			# the -Q options)
			res=SH.run_simple({'COLUMNS' => '1000'}, "pacman -#{local ? 'Q': 'S'}i #{pkgs.shelljoin}", chomp: :lines)
			key=nil; info={}
			res.each do |l|
				if key==:optional_deps and (m=l.match(/^\s+(\w*):\s+(.*)$/))
					#here we cannot split(':') because we need to check for the leading space
					info[key][m[1]]=m[2]
				else
					key, value=l.split(/\s*:\s*/,2)
					if key.nil? #new package
						list << info; key=nil; info={}
						next
					end
					key=key.strip.downcase.gsub(' ', '_').to_sym
					case key
					when :optional_deps
						dep, reason=value.split(/\s*:\s*/,2)
						value={dep => reason}
					when :groups, :provides, :depends_on, :required_by, :optional_for, :conflicts_with, :replaces
						value=to_list.call(value)
					when :install_script
						value=false if value=="No"
						value=true if value=="Yes"
					when :install_date, :build_date
						value=Time.parse(value)
					end
					info[key]=value
				end
			end
			# no need to add the last info, pacman -Q/Si always end with a new line
			list
		end

		def self.pacinfo(*pkgs) #this refers to the local db info
			list=[]; info={}
			res=SH.run_simple("pacinfo #{pkgs.shelljoin}", chomp: :lines)
			res.each do |l|
				key, value=l.split(/\s*:\s*/,2)
				if key.nil? #next package
					list << info; info={}
					next
				end
				key=key.downcase.gsub(' ', '_').to_sym
				case key
				when :install_script
					value=false if value=="No"
					value=true if value=="Yes"
				when :install_date, :build_date
					value=Time.parse(value)
				end
				Archlinux.add_to_hash(info, key, value)
			end
			# no need to add at the end, pacinfo always end with a new line
			list
		end

		def self.info(*packages)
			if SH.find_executable("pacinfo")
				pacinfo(*packages)
			else
				pacman_info(*packages)
			end
		end

		# Exemple: Archlinux::Repo.packages(* %x/pacman -Qqm/.split)
		# Warning: this does not use config, so this is just for a convenience
		# helper. Use RepoPkgs for install/config stuff
		def self.packages(*packages)
			PackageList.new(info(*packages))
		end

		def self.foreign_list
			%x(pacman -Qqm).split
		end

		def self.foreign_packages
			packages(*foreign_list)
		end
	end

	# can combined several repos
	class RepoPkgs
		extend CreateHelper
		attr_accessor :list, :config

		def initialize(list, config: Archlinux.config)
			@list=list
			@config=config
		end

		def infos
			Repo.info(*@list)
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages ||= @config.to_packages(infos)
		end
	end

	class LocalRepo
		extend CreateHelper
		attr_accessor :dir, :config

		def initialize(dir="/var/lib/pacman/local", config: Archlinux.config)
			@dir=Pathname.new(dir)
			@config=config
		end

		def infos
			#todo: this is essentially the same code as for db repo; factorize this?
			list=[]
			@dir.glob("*/desc").each do |desc|
				pkg={repo: :local}; mode=nil
				desc.read.each_line do |l|
					next if l.empty?
					if (m=l.match(/^%([A-Z0-9]*)%$/))
						mode=m[1].downcase.to_sym
					else
						l=l.to_i if mode==:csize or mode==:isize
						l=Time.at(l.to_i) if mode==:builddate
						Archlinux.add_to_hash(pkg, mode, l)
					end
				end
				list << pkg
			end
			list
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages ||= @config.to_packages(infos)
		end
	end

	# a list of packages archives
	class PackageFiles
		extend CreateHelper

		attr_accessor :files
		def initialize(*files, config: Archlinux.config)
			files=files.flatten #in case we are used with create
			@files=files.map {|file| Pathname.new(file)}
			@config=config
		end

		def infos
			# expac_infos
			bsdtar_infos
		end
		
		def bsdtar_infos
			list=[]
			@files.each do |file|
				info={repo: file}
				SH.run_simple("bsdtar -xOqf #{file.shellescape} .PKGINFO", chomp: :lines) do |error|
					SH.logger.info "Skipping #{file}: #{error}"
					next
				end.each do |l|
					next if l=~/^#/
					key, value=l.split(/\s*=\s*/,2)
					key=key.to_sym
					case key
					when :builddate
						value=Time.at(value.to_i)
					when :size
						key=:install_size; value=value.to_i
					when :pkgver
						key=:version
					end
					Archlinux.add_to_hash(info, key, value)
				end
				# no need to add at the end, pacinfo always end with a new line
				list << info
			end
			list
		end

		def expac_infos(slice=200) #the command line should not be too long
			format={
				filename: "%f",
				pkgname: "%n",
				pkgbase: "%e",
				version: "%v",
				url: "%u",
				description: "%d",
				packager: "%p",
				architecture: "%a",
				build_date: "%b",
				download_size: "%k",
				install_size: "%m",
				depends: "%D",
				conflicts: "%H",
				opt_depends: "%O",
				provides: "%P",
				replaces: "%T",
				# format << "%r\n" #repo
			}
			total=format.keys.count
			r=[]; delim="  ,  "
			split=lambda do |l| l.split(delim) end
			@files.each_slice(slice) do |files|
				SH.run_simple("expac --timefmt=%s #{format.values.join("\n").shellescape} -l #{delim.shellescape} -p #{files.shelljoin}", chomp: :lines).each_slice(total).with_index do |l,i|
					info={}
					format.keys.each_with_index do |k, kk|
						value=l[kk]
						value=split[value] if %i(depends conflicts opt_depends provides replaces).include?(k)
						value=nil if k==:pkgbase and value=="(null)"
						value=Time.at(value.to_i) if k==:build_date
						value=value.to_i if k==:download_size or k==:install_size
						info[k]=value if value
					end
					info[:repo]=files[i]
					r<<info
				end
			end
			r
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages ||= @config.to_packages(self.infos)
		end

		def sign(sign_name: :package, **opts)
			@config&.sign(*@files, sign_name: sign_name, **opts)
		end

		def self.rm_files(*files, dir: nil)
			deleted=[]
			files.each do |file|
				path=Pathname.new(file)
				path=dir+path if path.relative? and dir
				if path.exist?
					path.rm 
					deleted << path
				end
				sig=Pathname.new("#{path}.sig")
				if sig.exist?
					sig.rm 
					deleted << sig
				end
			end
			SH.logger.verbose2 "Deleted: #{deleted}"
			deleted
		end

		# pass packages names to remove
		def rm_pkgs(*pkgs)
			files=[]
			pkgs.each do |pkg_name|
				pkg=packages.fetch(pkg_name, nil)
				files << pkg.path if pkg
			end
			@packages=nil #we need to refresh the list.
			self.class.rm_files(*files)
		end

		def clean(dry_run: true)
			to_clean=[]
			latest=packages.latest.values
			packages.each do |_name, pkg|
				to_clean << pkg unless latest.include?(pkg)
			end
			if block_given?
				to_clean = yield to_clean
			end
			unless dry_run
				to_clean.each do |f| 
					p=f.path
					p.rm if p.exist?
					sig=Pathname.new(p.to_s+".sig")
					sig.rm if sig.exist?
				end
			end
			return to_clean.map {|pkg| pkg.path}, to_clean
		end

		def self.from_dir(dir, config: Archlinux.config)
			dir=Pathname.new(dir)
			list=dir.glob('*.pkg.*').map do |g| 
				next if g.to_s.end_with?('~') or g.to_s.end_with?('.sig')
				f=dir+g
				next unless f.readable?
				f
			end.compact
			self.new(*list, config: config)
		end
	end
end
