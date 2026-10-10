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

**Not in this patch:** `filter-aaaa-on-v4` (with `$filter_ipv6`) -- it is nb.4, below.

Rendered with the fleet's values before and after (Ruby ERB, trim mode `-`, as Puppet
renders): exactly the two lines removed, no other byte of the options block changes.

### nb.4 — retire `filter-aaaa-on-v4` (NiobiumInc/it#103, option B)

The third directive the 2021 template still emitted, `filter-aaaa-on-v4 yes` (with
`$filter_ipv6`), is gone from the options template. `$filter_ipv6` stays as a class
parameter so existing data keeps compiling, but nothing reads it any more.

| directive | BIND 9.11.36 (el8: carbonite, smellerbee) | BIND 9.16.23 (el9: jet, longshot, pipsqueak, theduke) | BIND 9.18 |
|---|---|---|---|
| `filter-aaaa-on-v4 yes` | live: AAAA records are withheld from answers over IPv4 (recursion only; the zones carry no AAAA) | "obsolete and should be removed" -- ignored; the policy moved to the `filter-aaaa.so` plugin in 9.13 | removed from `options`: `named` refuses to start |

Why retire rather than port to the plugin (joel, 2026-10-05, it#103): AAAA filtering is not a
security control, the four 9.16 servers had silently stopped filtering months before anyone
noticed, and jet (first in every resolver list) is one of them; IPv6 exposure is tracked as
its own topic (it#25). **Behaviour change, on two servers only:** smellerbee and carbonite
(9.11) stop withholding AAAA from recursive answers over IPv4 and come into line with the
other four. Authoritative answers are unchanged (no AAAA in our zones).

Rendered with the fleet's values before and after (Ruby ERB, trim mode `-`): exactly the one
line removed with `$filter_ipv6 => true`; byte-identical with `false`.

### nb.5 — allow the CAA record type

`resource_record`'s `type` parameter is an allowlist, and CAA (RFC 8659) was not on it, so a
`bind::resource_record` hiera entry with `type: 'CAA'` failed the whole catalog on the
nameservers. The nsupdate provider is type-generic; the allowlist was the only block.

CAA is deliberately **not** added to the provider's quoted or escaped type lists. The value
carries its own quotes, so hiera holds the whole rdata, e.g.
`'0 issue "digicert.com; accounturi=https://digicert.com/account/<id>"'`, and nsupdate gets it
verbatim. `dig` prints CAA rdata back in that same form, with the `;` inside the quotes left
unescaped (checked against live records, e.g. cloudflare.com's
`0 issue "digicert.com; cansignhttpexchanges=yes"`), so the provider's data comparison stays in
sync and does not rewrite the record on every run. BIND has served CAA since 9.10.1, so every
server in the fleet (9.11 and 9.16) accepts it.

### nb.6 — no stdlib functions that stdlib 9 removed (NiobiumInc/it#360)

The control repo is moving to puppetlabs-stdlib 9 so that the modules can run on Puppet/OpenVox 8.
stdlib 9 removed the `is_*` and `validate_*` families (and others) without a replacement in Puppet
core. This module called one of them: `is_bool($supported)` in `bind::defaults`, the guard that the
OS data loaded. It is now `$supported =~ Boolean`, the same test (true only for a real Boolean), and
it works on stdlib 6.5 and 9 alike, so the pin can move before the stdlib bump. No other call to a
removed function remains in `manifests/` or `templates/`.

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
- `7.4.0+nb.4` -- - `filter-aaaa-on-v4` from the options template (it#103, option B); `$filter_ipv6`
  accepted and ignored. smellerbee/carbonite stop filtering AAAA in recursive answers.
- `7.4.0+nb.5` -- + `CAA` in `resource_record`'s type allowlist. No change for existing records.
- `7.4.0+nb.6` -- `is_bool()` -> `=~ Boolean` in `bind::defaults` for stdlib 9 (it#360). Same test; no catalog change.
