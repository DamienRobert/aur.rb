require 'aur/version'
require 'aur/config'
require 'aur/aur_rpc'
require 'aur/db'
require 'aur/repos'
require 'aur/versions'
require 'aur/devtools'
require 'aur/makepkg'
require 'aur/packages'
require 'aur/install_packages'

=begin
# query aur
Archlinux::AurQuery.packages("pacaur")

# Make a package
m=Archlinux::Makepkg.new("pacaur")
m.edit
m.makepkg("--geninteg") #update PKGBUILD (todo: add a function for that?)
m.install

# install a package
aur=Archlinux::AurPackageList.new([])
l=aur.install("pacaur")

# check update and new installation compared to a db
aur=Archlinux.config.db.packages
aur=Archlinux.config.default_packages #or get default packages
aur.update?
aur.install?("pacaur", update: true)

# Clean/Change cache:
Archlinux.config.instance_variable_set(:@install_list, nil)
aur.install_list=Archlinux.config.install_list


# Update a db with the latest packages available on the local filesystem
db=Archlinux.config.db
db.check_udpate / db.update
# see package names
db.packages.l.keys

# Check for useless packages in the db
pkgs = Archlinux.config.db.packages
needed = pkgs.rget(*wanted_pkgs)
# present = pkgs.latest.keys ## we want the version
present = pkgs.l.keys
notneeded=present - needed
files=pkgs.slice(*notneeded).map {|k,v| v.file}
db.remove(*files)
=end
