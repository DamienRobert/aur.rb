require 'aur/version'
require 'aur/config'
require 'aur/aur_rpc'
require 'aur/db'
require 'aur/repos'
require 'aur/versions'
require 'aur/devtools'
require 'aur/makepkg'
require 'aur/packages'

=begin
aur=Archlinux::AurPackageList.new([])
l=aur.install("pacaur")

aur=Archlinux.config.db.packages
aur.update?
aur.install?("pacaur", update: true)

# Clean/Change cache:
Archlinux.config.instance_variable_set(:@install_list, nil)
aur.install_list=Archlinux.config.install_list

db=Archlinux.config.db
db.check_udpate
db.update
=end

# TODO:
# MakepkgList.from_dir
# --devel switch?
# aur search cache
# repo list of foreign packages
# view only when updated/new
# confirm before installing or updating pkgver (this is somewhat orthogonal to exiting when view return false since we may want to not view the files)
# cli
# tests
# default package list (think of the case of the user who don't want a db)
