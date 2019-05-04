require 'aur/config'
require 'aur/packages'
require 'aur/repos'
require 'time'

module Archlinux
	class DB
		extend CreateHelper

		def self.db_file?(name)
			case name
			when Pathname
				true
			when String
				if name.include?('/') or name.match(/\.db(\..*)?$/)
					true
				else
					false #Usually we assume this is a repo name
				end
			end
		end

		attr_accessor :file, :config
		def initialize(file, config: Archlinux.config)
			@orig_file=Pathname.new(file)
			@file=@orig_file.realdirpath rescue @orig_file.abs_path
			@config=config
		end

		def mkpath
			@file.dirname.mkpath
		end

		def path
			if file.exist?
				file.realpath
			else
				file
			end
		end

		def repo_name
			@file.basename.to_s.sub(/\.db(\..*)?$/,'')
		end

		def create
			mkpath
			unless @file.exist?
				call(:'repo-add', path)
			end
			self
		end

		def to_s
			@file.to_s
		end

		# a db is a tar.gz archive of packages/desc, like yay-8.998-1/descr
		def bsdcat_list
			res= SH.run_simple("bsdcat #{@file.shellescape}", chomp: :lines) {return nil}
			list=[]; pkg={}; mode=nil
			flush = lambda do
				# catch old deps files which don't specify the full infos
				unless pkg[:name].nil? and pkg[:base].nil?
					pkg[:repo]||=path
					list << pkg 
				end
			end
			res.each do |l|
				next if l.empty? or l.match(/^\u0000*$/)
				if (m=l.match(/(\u0000+.*\u0000+)?%([A-Z0-9]*)%$/))
					mode=m[2].downcase.to_sym
					if m[1] #new db entry
						flush.call #store old db entry
						pkg={}
					end
				else
					l=l.to_i if mode==:csize or mode==:isize
					l=Time.at(l.to_i) if mode==:builddate
					Archlinux.add_to_hash(pkg, mode, l)
				end
			end
			flush.call #don't forget the last one
			list
		end

		def list
			res= SH.run_simple("bsdtar -xOf #{@file.shellescape} '*/desc'", chomp: :lines) {return nil}
			list=[]; pkg={}; mode=nil
			flush = lambda do
				unless pkg.empty?
					pkg[:repo]||=path
					list << pkg
				end
			end
			res.each do |l|
				next if l.empty?
				if (m=l.match(/^%([A-Z0-9]*)%$/))
					mode=m[1].downcase.to_sym
					if mode==:filename #new db entry
						flush.call #store old db entry
						pkg={}
					end
				else
					l=l.to_i if mode==:csize or mode==:isize
					l=Time.at(l.to_i) if mode==:builddate
					Archlinux.add_to_hash(pkg, mode, l)
				end
			end
			flush.call #don't forget the last one
			list
		end

		def files(absolute=true)
			list.map do |pkg|
				file=Pathname.new(pkg[:filename])
				absolute ? dir + file : file
			end
		end
		# def files
		# 	packages.l.map {|pkg| dir+Pathname.new(pkg[:filename])}
		# end

		def dir
			# # we memoize this because if we get called again in a dir.chdir
			# # call, then the realpath will fail
			# @dir ||= @file.dirname.realpath
			@file.dirname
		end

		def call(*args)
			@config.launch(*args) do |*args|
				dir.chdir do
					SH.sh(*args)
				end
			end
		end

		def move_to_db(*files, op: :mv)
			files=files.map {|f| Pathname.new(f).realpath}
			dir=self.dir
			SH.logger.verbose "#{op}: #{files.join(', ')} to #{dir}"
			files.map do |f|
				if f.dirname == dir
					SH.logger.verbose2 "! #{f} already exists in #{dir}"
					f
				else
					new=dir+f.basename
					SH.logger.verbose2 "-> #{op} #{f} to #{new}"
					f.send(op, new)
					sig=Pathname.new(f.to_s+".sig") #mv .sig too
					if sig.exist?
						newsig=dir+sig.basename
						SH.logger.verbose2 "-> #{op} #{sig} to #{newsig}"
						sig.send(op, newsig)
					end
					new
				end
			end
			files
		end

		def add(*files, cmd: :'repo-add', default_opts:[], sign: @config&.use_sign?(:db), force_sign: false, **opts)
			default_opts+=['-s', '-v'] if sign
			default_opts+=['--key', sign] if sign.is_a?(String)
			dir.chdir do
				files.map! {|f| Pathname.new(f)}
				existing_files=files.select {|f| f.file?}
				missing_files = files-existing_files
				SH.logger.warn "In #{cmd}, missing files: #{missing_files.join(', ')}" unless missing_files.empty?
				unless existing_files.empty?
					sign_files = @config&.use_sign?(:package)
					PackageFiles.new(*existing_files, config: @config).sign(sign_name: sign_files, force: force_sign) if sign_files
					call(cmd, path, *existing_files, default_opts: default_opts, **opts)
				end
			end
		end

		def remove(*args, **opts)
			add(*args, cmd: :'repo-remove', **opts)
		end

		def packages(refresh=false)
			@packages=nil if refresh
			# @packages||=PackageList.new(list, config: @config)
			@packages||=@config.to_packages(list)
		end

		def dir_packages(packages: true)
			pkg_files=PackageFiles.from_dir(dir, config: @config)
			pkg_files=pkg_files.packages if packages
			pkg_files
		end

		def package_files(packages: true)
			pkg_files=PackageFiles.new(*files, config: @config)
			pkg_files=pkg_files.packages if packages
			pkg_files
		end

		# sign the files in the db (return the list of signed file, by default
		# unless force: true is passed this won't resign already signed files)
		def sign_files(sign_name: :package, **opts)
			@config&.sign(*files, sign_name: sign_name, **opts)
		end
		def sign_db(sign_name: :db, **opts)
			@config&.sign(@file, sign_name: sign_name, **opts) if @file.file?
		end

		def verify_sign_db
			@config&.verify_sign(@file)
		end
		def verify_sign_files
			@config&.verify_sign(*files)
		end
		# check the inline signatures
		def verify_sign_pkgs(*pkgs)
			packages.get_packages(*pkgs).map do |pkg|
				pgpsign=pkg[:pgpsig]
				if pgpsign
					require 'base64'
					sig=Base64.decode64(pgpsign)
					filename=dir+pkg[:filename]
					@config.launch(:gpg, "--enable-special-filenames", "--verify", "-", filename, mode: :capture, stdin_data: sig) do |*args|
						suc, _r=SH.sh(*args)
						[pkg.name, suc]
					end
				else
					[pkg.name, false]
				end
			end.to_h
		end

		# if we missed some signatures, resign them (and add them back to the
		# db to get the signatures in the db). This override the sign:false
		# config options.
		def resign(**opts)
			signed_files=sign_files(**opts)
			add(*signed_files) #note that this may try to sign again, but since the signature exists it won't launch gpg
			sign_db(**opts) #idem, normally the db will be signed by repo-add -v, but in case the signature was turned off in the config, this forces the signautre
		end

		def check
			packages.same?(package_files)
		end

		def check_update(other=dir_packages)
			up=self.packages.check_updates(other)
			yield up if block_given?
			refresh=up.select {|_k, u| u[:op]==:upgrade or u[:op]==:downgrade}
			add=up.select {|_k, u| u[:op]==:install}
			remove=up.select {|_k, u| u[:op]==:obsolete}
			return {refresh: refresh, add: add, remove: remove}
		end

		def show_updates(other=dir_packages)
			check_update(other) do |c|
				packages.show_updates(c, obsolete: true)
			end
		end

		def update(other=dir_packages)
			r=check_update(other)
			add(*(r[:refresh].merge(r[:add])).map do |_k,v|
				other[v[:out_pkg]].path
			end)
			# remove(*(r[:remove].map {|_k,v| packages[v[:in_pkg]].file.shellescape}))
			remove(*(r[:remove].map {|_k,v| Query.strip(v[:in_pkg])}))
			@packages=nil #we need to refresh the list
			r
		end

		# move/copy files to db and add them
		# if update==true, only add more recent packages
		# pkgs should be a PackageFiles or a PackageList or a list of files
		def add_to_db(pkgs, update: true, op: :cp)
			if update
				pkgs=PackageFiles.create(pkgs).packages unless pkgs.is_a? PackageList
				up=self.packages.check_updates(pkgs)
				pkgs=up.select {|_k, u| u[:op]==:upgrade or u[:op]==:install}.map do |_k,v|
					pkgs[v[:out_pkg]].path
				end
			else
				pkgs=pkgs.map {|_k,v| v.path } if pkgs.is_a?(PackageList)
			end
			SH.logger.mark "Updating #{pkgs} in #{self}"
			cp_pkgs=move_to_db(*pkgs, op: op)
			add(*cp_pkgs)
		end

		def clean(dry_run: true)
			files=dir_packages(packages: false)
			files.clean(dry_run: dry_run)
		end
	end
end
