# ex: syntax=puppet si ts=4 sw=4 et

class bind (
    $forwarders                           = undef,
    $forward                              = undef,
    $dnssec                               = undef,
    $filter_ipv6                          = undef,
    $version                              = undef,
    $statistics_port                      = undef,
    $auth_nxdomain                        = undef,
    $include_default_zones                = true,
    $include_local                        = false,
    $tkey_gssapi_credential               = undef,
    $tkey_domain                          = undef,
    $chroot                               = false,
    $chroot_class                         = $::bind::defaults::chroot_class,
    $chroot_dir                           = $::bind::defaults::chroot_dir,
    # NOTE: we need to be able to override this parameter when declaring class,
    # especially when not using hiera (i.e. when using Foreman as ENC):
    $default_zones_include                = $::bind::defaults::default_zones_include,
) inherits bind::defaults {
    if $chroot and !$::bind::defaults::chroot_supported {
        fail('Chroot for bind is not supported on your OS')
    }
    File {
        ensure  => present,
        owner   => 'root',
        group   => $::bind::defaults::bind_group,
        mode    => '0644',
        require => Package['bind'],
        # NIOBIUM (it#247): config files refresh the validate gate below, and
        # only the gate refreshes the service. Upstream notified the service
        # directly, so an invalid render restarted named into a failure.
        notify  => Exec['bind-validate-config'],
    }

    include ::bind::updater

    package { 'bind':
        ensure => latest,
        name   => $::bind::defaults::bind_package,
    }

    if $chroot and $::bind::defaults::chroot_class {
        # When using a dedicated chroot class, service declaration is dedicated to this class
        class { $::bind::defaults::chroot_class : }
    }

    # NIOBIUM (it#247): validate the WHOLE rendered configuration before the
    # service is refreshed. Every managed config file (File defaults above,
    # the concat targets below, bind::key's key files, bind::zone's per-zone
    # conf) notifies this Exec instead of Service['bind']; the Exec notifies
    # the service. When named-checkconf fails, Puppet reports the Exec failed
    # and SKIPS the dependent service refresh, so named keeps serving its
    # in-memory config -- the restart is blocked, not the write. named-checkconf
    # follows the include directives in named.conf and names the offending
    # file and line, which is why the gate runs on named.conf and not as a
    # validate_cmd on the fragments (they reference ACLs and keys defined in
    # other includes and are never valid on their own -- measured, it#247).
    # named-checkconf ships in the bind package. With a chroot, named resolves
    # its includes inside it, so the check must too (-t).
    # A chroot with no chroot_dir would make the selector below fall to the
    # host-side command and validate the wrong tree -- precisely in the case
    # -t exists for. On RHEL the module's own data leaves chroot_dir unset
    # ("# XXX bind::defaults::chroot_dir" in data/os/RedHat.yaml), so this is
    # the shape a future chroot enablement would hit. Refuse rather than
    # check the wrong thing (!204 review).
    if $chroot and !$chroot_dir {
        fail('bind: chroot is enabled but chroot_dir is unset; named-checkconf would validate the host config instead of the chroot (NiobiumInc/it#247)')
    }
    $checkconf_cmd = ($chroot and $chroot_dir) ? {
        true    => "named-checkconf -t ${chroot_dir} ${::bind::defaults::namedconf}",
        default => "named-checkconf ${::bind::defaults::namedconf}",
    }
    exec { 'bind-validate-config':
        command     => $checkconf_cmd,
        path        => '/usr/sbin:/usr/bin:/sbin:/bin',
        refreshonly => true,
        logoutput   => on_failure,
        require     => Package['bind'],
        notify      => Service['bind'],
    }

    if $dnssec {
        file { '/usr/local/bin/dnssec-init':
            ensure => present,
            owner  => 'root',
            group  => 'root',
            mode   => '0755',
            source => 'puppet:///modules/bind/dnssec-init',
        }
    }

    # rndc only supports HMAC-MD5
    bind::key { 'rndc-key':
        algorithm   => 'hmac-md5',
        secret_bits => '512',
        keydir      => $bind::defaults::confdir,
        keyfile     => 'rndc.key',
        include     => false,
    }

    file { '/usr/local/bin/rndc-helper':
        ensure  => present,
        owner   => 'root',
        group   => 'root',
        mode    => '0755',
        content => template('bind/rndc-helper.erb'),
    }

    file { "${::bind::defaults::confdir}/zones":
        ensure => directory,
        mode   => '2755',
    }

    file { $::bind::defaults::namedconf:
        content => template('bind/named.conf.erb'),
    }

    if $include_default_zones and $::bind::defaults::default_zones_source {
        file { $default_zones_include:
            source => $::bind::defaults::default_zones_source,
        }
    }

    class { '::bind::keydir':
        keydir => "${::bind::defaults::confdir}/keys",
    }

    concat { [
        "${::bind::defaults::confdir}/acls.conf",
        "${::bind::defaults::confdir}/keys.conf",
        "${::bind::defaults::confdir}/views.conf",
        "${::bind::defaults::confdir}/servers.conf",
        "${::bind::defaults::confdir}/logging.conf",
        "${::bind::defaults::confdir}/view-mappings.txt",
        "${::bind::defaults::confdir}/domain-mappings.txt",
        ]:
        owner   => 'root',
        group   => $::bind::defaults::bind_group,
        mode    => '0644',
        warn    => true,
        require => Package['bind'],
        notify  => Exec['bind-validate-config'],   # NIOBIUM (it#247): via the gate
    }

    concat::fragment { 'bind-logging-header':
        order   => '00-header',
        target  => "${::bind::defaults::confdir}/logging.conf",
        content => "logging {\n";
    }

    concat::fragment { 'bind-logging-footer':
        order   => '99-footer',
        target  => "${::bind::defaults::confdir}/logging.conf",
        content => "};\n";
    }

    # DO NOT declare a bind service when chrooting bind with bind::chroot::package class,
    # because it needs another dedicated chrooted-bind service (i.e. named-chroot on RHEL)
    # AND it also needs $::bind::defaults::bind_service being STOPPED and DISABLED.
    if !$chroot or ($chroot and $::bind::defaults::chroot_class == 'bind::chroot::manual') {
        service { 'bind':
            ensure     => running,
            name       => $::bind::defaults::bind_service,
            enable     => true,
            hasrestart => true,
            hasstatus  => true,
        }
    }
}
