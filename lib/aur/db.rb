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
			@file=Pathname.new(file)
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
				call(:'repo-add', path.shellescape)
			end
			self
		end

		def to_s
			@file.to_s
		end

		# a db is a tar.gz archive of packages/desc, like yay-8.998-1/descr
		def list
			require 'dr/sh'
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
			@file.dirname.realpath
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
			files.map do |f|
				if f.dirname == dir
					f
				else
					new=dir+f.basename
					f.send(op, new)
					new
				end
			end
			files
		end

		def add(*files, cmd: :'repo-add', default_opts:[], sign: @config&.use_sign(:db), **opts)
			default_opts+=['-s', '-v'] if sign
			default_opts+=['--key', sign] if sign.is_a?(String)
			dir.chdir do
				files.map! {|f| Pathname.new(f)}
				existing_files=files.select {|f| f.file?}
				missing_files = files-existing_files
				SH.logger.warn "In #{cmd}, missing files: #{missing_files.join(', ')}" unless missing_files.empty?
				unless existing_files.empty?
					sign_files = @config&.use_sign(:package)
					PackageFiles.new(*existing_files, config: @config).sign(sign_name: sign_files) if sign_files
					call(cmd, path.shellescape, *existing_files, default_opts: default_opts, **opts)
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

		def dir_packages
			PackageFiles.from_dir(dir, config: @config).packages
		end

		def package_files
			PackageFiles.new(*files, config: @config).packages
		end

		def sign_files(sign_name: :package, **opts)
			files.map do |pkg|
				@config&.sign(pkg, sign_name: sign_name, **opts) if pkg.file?
			end.compact
		end
		def sign_db(sign_name: :db, **opts)
			@config&.sign(@file, sign_name: sign_name, **opts) if @file.file?
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
			refresh=up.select {|_k, u| u[:op]==:upgrade or u[:op]==:downgrade}
			add=up.select {|_k, u| u[:op]==:install}
			remove=up.select {|_k, u| u[:op]==:obsolete}
			return {refresh: refresh, add: add, remove: remove}
		end

		def update(other=dir_packages)
			r=check_update(other)
			add(*(r[:refresh].merge(r[:add])).map {|_k,v| other[v[:out_pkg]].file.shellescape})
			# remove(*(r[:remove].map {|_k,v| packages[v[:in_pkg]].file.shellescape}))
			remove(*(r[:remove].map {|_k,v| Query.strip(v[:in_pkg])}))
			@packages=nil #we need to refresh the list
			r
		end
	end
end
