# Api

- tests
- check if splitpackages are handled correctly
- add doc

## Improvements

- replace AurMakepkgCache with a more generic aggregator
- using tsort in rget won't do a breadth first search, which would reduce
the number of aur queries. With tsort packages are queried one by one.
- split Makepkg into a class for downloading/viewing/querying and the
class for installing. This will allow to support both github and the aur
rpc.
- preference to decide which :provides to choose
  (and favorise local packages for provides)

## UI

- view only when updated/new + add trusted PKGBUILD
- confirm before installing or updating pkgver (this is somewhat orthogonal to exiting when view return false since we may want to not view the files)
- due to vercmp, we need to reset packages before pulling
  => use stash?
- allow to check for packages that are moved from aur to the official db
    and conversely

# Bugs

- in `official` we need to also list packages provided by them, eg
  libarchive provides libarchive.so (but libarchive.so does not exist
  separately, but eg aurutils-git requires it)
- also when we have custom packages in our db (not in aur), we get missing
    warnings for these packages
- when using AurMakepkgCache, missing packages info are repeated several times
- in `sync_db` setup a simily local cache so that the packages don't get copied twice (ie both in `/var/cache/pacman` and in `~/.cache/arch_aur/.db`).
- makechrootpkg does not propagate 'PKGEXT' setting. So if we use zstd in
    our local makepkg.conf, `aur.rb` will expect a `zst` package to be
    built, but an `xz` will be built instead (per the default
    `makepkg.conf` in the chroot). Not sure how to fix this. The solution
    is to specify devtool's `makepkg.conf` for chroot builds (cf the
    config).

# CLI

- in db update, allow to be more atomic, same for clean
  That is we want to be able to specify which packages we want to
  update/clean

- in `aur install`: 
  - add --no-fetch and --fetch=only (or add an extra command specialised in
      fetching PKGBUILD?);
  - add --extra-db= to specify an external db
  - add --buildopts="..." that gets passed to our build function

- Add packages informations:
  - 'package info'
  - 'package compare' [DONE]
  - 'package list' [DONE]

- Expand around our temp pacman config features to remake `checkupdates` in
    a more flexible way. For instance to only update our extra database on
    interact with our `aur` database. Would need features to symlink the
    local database too.

- Clean `~/.cache/arch_aur`. Essentially a wrapper to call
  `for i in *(/); do git -C $i clean -ndx; done`

# Tools

- use https://github.com/falconindy/pkgbuild-introspection/ to  speed up .SRCINFO

