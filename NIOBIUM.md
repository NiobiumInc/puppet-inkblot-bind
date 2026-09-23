# Niobium fork of inkblot-bind (dwest-galois/puppet-bind @ 2f08cdb)

This repository is `dwest-galois/puppet-bind` at commit `2f08cdb219634b12f7783d79a46c243c4958a4b8`
(tag `upstream-2f08cdb`, the commit niobium-admin/puppet's Puppetfile pinned from 2021 until this
fork), plus Niobium patches. Each patch is marked `NIOBIUM (it#N)` in the source.

## Patches

### nb.1 — validate before restart (NiobiumInc/it#247)

Upstream notifies `Service['bind']` from every managed config file, so a config change
**restarts** named (`hasrestart => true`) with nothing checking the rendered configuration
first. An invalid render took named down on every server that applied it, from one
`common.yaml` edit, with no canary.

The fork adds `Exec['bind-validate-config']` (`named-checkconf <namedconf>`, `-t <chroot_dir>`
when chrooted, `refreshonly`) and points every config notify at it: the `File` defaults and the
`concat` targets in `init.pp`, the key file in `key.pp`, the per-zone conf in `zone.pp`. The Exec
notifies the service. When the check fails, Puppet reports the Exec as failed and skips the
dependent service refresh, so named keeps serving its in-memory configuration.

**What it does not do.** The gate blocks the *restart*, not the *write*: the invalid file is on
disk and a later restart from outside Puppet (an OS upgrade's package transaction, a reboot)
would still fail. `validate_cmd` on the fragments cannot close that gap -- they `include`
into named.conf and reference ACLs and keys defined in other fragments, so they are never
valid on their own (measured on `views.conf`: `undefined ACL 'niobium'`, `unknown key
'external-update'`). `named-checkconf` on the whole `named.conf` follows the includes and
reports the right file and line. Warnings (the it#103 obsolete directives) are not errors:
`named-checkconf` exits 0 on the fleet's config today, so the gate lands without a flag day.

## Versioning

`metadata.json` `version` is `7.4.0+nb.N` (`+`, not `-`: a `-` suffix is a prerelease and
sorts *before* 7.4.0; `+` is build metadata and sorts equal -- see the ghoneycutt-ssh fork's
NIOBIUM.md, it#222). This module was never a Forge tarball here, so there is no
`checksums.json` to re-stamp. Tag each release with the version string and update the
`commit:` pin in the control repo's Puppetfile.

## Tags

- `upstream-2f08cdb` -- what production pinned before the fork
- `7.4.0+nb.1` -- + the validate gate (it#247)
