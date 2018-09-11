require 'aur/helpers'
require 'aur/packages'
require 'time'

module Archlinux
	class Repo
		extend CreateHelper

		def initialize(name, config: Archlinux.config)
			@repo=name
			@config=config
		end

		def list(mode: :pacsift)
			command= case mode
			when :pacman, :name
				"pacman -Slq #{@repo.shellescape}" #returns pkg
			when :pacsift, :repo_name
				#this mode is prefered, so that if the same pkg is in different
				#repo, than pacman_info returns the correct info
				"pacsift --exact --repo=#{@repo.shellescape} <&-" #returns repo/pkg
			when :paclist, :name_version
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

		def self.packages(*packages)
			PackageList.new(info(*packages))
		end
	end

	class PackageFiles
		extend CreateHelper

		attr_accessor :files
		def initialize(*files, config: Archlinux.config)
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
				SH.run_simple("bsdtar -xOqf #{file.shellescape} .PKGINFO", chomp: :lines).each do |l|
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
			@packages ||= PackageList.new(self.infos)
		end

		def sign(sign_name: :package, **opts)
			@config&.sign(*@files, sign_name: sign_name, **opts)
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
