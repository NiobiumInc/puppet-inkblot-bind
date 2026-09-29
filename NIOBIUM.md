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

**Chroot.** With `$chroot` and `$chroot_dir` set the check runs as `named-checkconf -t <chroot_dir>`.
With `$chroot` set and `$chroot_dir` unset the class **fails** rather than silently validating the
host's view of the config -- and that is the shape RHEL data ships (`data/os/RedHat.yaml` leaves
`chroot_dir` commented out). Chroot is unreachable on the Niobium nameservers today
(`chroot_supported: false` on el8/el9, and `profile::inkblot_bind` passes no `chroot`), so the `-t`
branch has never executed here; whoever enables chroot owns setting `chroot_dir` and re-proving the
gate. **Zone data** is not covered either: `bind::zone`'s data file keeps its own `rndc reload`
(`named-checkconf` does not read zone files; `named-checkzone` does), so a malformed record fails at
reload and that zone keeps serving its previous copy.

**What it does not do.** The gate blocks the *restart*, not the *write*: the invalid file is on
disk and a later restart from outside Puppet (an OS upgrade's package transaction, a reboot)
would still fail. `validate_cmd` on the fragments cannot close that gap -- they `include`
into named.conf and reference ACLs and keys defined in other fragments, so they are never
valid on their own (measured on `views.conf`: `undefined ACL 'niobium'`, `unknown key
'external-update'`). `named-checkconf` on the whole `named.conf` follows the includes and
reports the right file and line. Warnings (the it#103 obsolete directives) are not errors:
`named-checkconf` exits 0 on the fleet's config today, so the gate lands without a flag day.

### nb.3 — drop two directives current BIND no longer accepts (NiobiumInc/it#103)

The options template rendered `dnssec-enable` (always) and `dnssec-lookaside auto` (with
`$dnssec`). Both are dead on the fleet's newer servers and fatal on the next BIND:

| directive | BIND 9.11.36 (el8: carbonite, smellerbee) | BIND 9.16.23 (el9: jet, longshot, pipsqueak, theduke) | BIND 9.18 |
|---|---|---|---|
| `dnssec-enable yes` | valid; `yes` **is the default** | "obsolete and should be removed" -- ignored | removed: `named` refuses to start |
| `dnssec-lookaside auto` | "'auto' is no longer supported" (ISC's DLV registry shut down in 2017) | "obsolete" -- ignored | removed |

Measured with `named-checkconf` on all six servers, 2026-09-24 (it#247). Removing both is
behaviour-neutral for this fleet: it renders `dnssec => true`, whose `dnssec-enable yes` is
9.11's own default, and DLV has answered nothing since 2017. `dnssec-validation yes` stays.

**One semantic change, outside this fleet:** with `dnssec => false` the template used to
render `dnssec-enable no`; now it renders nothing, so on a 9.11 server DNSSEC *processing*
stays at its default (on) and only validation is off. On 9.16+ the old line was ignored anyway.

**Not in this patch:** `filter-aaaa-on-v4` (with `$filter_ipv6`). It is live policy on 9.11
and ignored on 9.16+ (it moved to the `filter-aaaa.so` plugin in 9.13), and 9.18 rejects it
in `options` -- so it must change too, but whether the fleet keeps the policy (plugin on
9.16+) or retires it is joel's call on it#103, and it lands as nb.4.

Rendered with the fleet's values before and after (Ruby ERB, trim mode `-`, as Puppet
renders): exactly the two lines removed, no other byte of the options block changes.

## Versioning

`metadata.json` `version` is `7.4.0+nb.N` (`+`, not `-`: a `-` suffix is a prerelease and
sorts *before* 7.4.0; `+` is build metadata and sorts equal -- see the ghoneycutt-ssh fork's
NIOBIUM.md, it#222). This module was never a Forge tarball here, so there is no
`checksums.json` to re-stamp. Tag each release with the version string and update the
`commit:` pin in the control repo's Puppetfile.

## Tags

- `upstream-2f08cdb` -- what production pinned before the fork
- `7.4.0+nb.1` -- + the validate gate (it#247)
- `7.4.0+nb.2` -- + `fail()` when chroot is enabled without chroot_dir; NIOBIUM.md states the chroot and
  zone-data limits (!204 review). Gate behaviour on a non-chroot host unchanged.
- `7.4.0+nb.3` -- - `dnssec-enable` and `dnssec-lookaside auto` from the options template (it#103);
  behaviour-neutral with `dnssec => true`.
