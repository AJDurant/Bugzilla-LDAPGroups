# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::LDAPGroups;

use 5.10.1;
use strict;
use parent qw(Bugzilla::Extension);

use Bugzilla::Error qw(ThrowUserError ThrowCodeError);
use Bugzilla::Util qw(diff_arrays trim clean_text);

use Bugzilla::Extension::LDAPGroups::Util qw(sync_ldap bind_ldap_for_search);

# Import this class now so its methods can be overriden
use Bugzilla::WebService::Group;

use Scalar::Util qw(blessed);

use constant GRANT_LDAP => 3;

our $VERSION = '0.01';


BEGIN {
    no warnings 'redefine';
    *Bugzilla::ldap = \&_bugzilla_ldap;
    *Bugzilla::Auth::Verify::_orig_create_or_update_user
        = \&Bugzilla::Auth::Verify::create_or_update_user;
    *Bugzilla::Auth::Verify::create_or_update_user = \&_create_or_update_user;
    *Bugzilla::Group::_orig_update = \&Bugzilla::Group::update;
    *Bugzilla::Group::update = \&_group_update;
    *Bugzilla::Group::_orig_create = \&Bugzilla::Group::create;
    *Bugzilla::Group::create = \&_group_create;
    # Override _group_to_hash because there isn't a hook
    *Bugzilla::WebService::Group::_orig_group_to_hash = \&Bugzilla::WebService::Group::_group_to_hash;
    *Bugzilla::WebService::Group::_group_to_hash = \&_group_to_hash;
    *Bugzilla::Group::ldap_dn = sub { $_[0]->{ldap_dn}; };
    *Bugzilla::Group::set_ldap_dn = sub { $_[0]->set('ldap_dn', $_[1]); };
};

# From Bugzilla::Auth::Verify::LDAP
# Adds use of cache for ldap object
sub _bugzilla_ldap {
    my $class = shift;

    return $class->request_cache->{ldap}
        if defined $class->request_cache->{ldap};

    my @servers = split(/[\s,]+/, Bugzilla->params->{"LDAPserver"});
    ThrowCodeError("ldap_server_not_defined") unless @servers;

    require Net::LDAP;
    my $ldap;
    foreach (@servers) {
        $ldap = new Net::LDAP(trim($_));
        last if $ldap;
    }
    ThrowCodeError("ldap_connect_failed",
        { server => join(", ", @servers) }) unless $ldap;

    # try to start TLS if needed
    if (Bugzilla->params->{"LDAPstarttls"}) {
        my $mesg = $ldap->start_tls();
        ThrowCodeError("ldap_start_tls_failed", { error => $mesg->error() })
            if $mesg->code();
    }
    $class->request_cache->{ldap} = $ldap;

    return $class->request_cache->{ldap};
}

sub _create_or_update_user {
    my ($self, $params) = @_;
    my $dbh = Bugzilla->dbh;

    my $result = $self->_orig_create_or_update_user($params);

    if (exists $params->{ldap_group_dns}) {

        my $sth_add_mapping = $dbh->prepare(
            qq{INSERT INTO user_group_map
                 (user_id, group_id, isbless, grant_type)
               VALUES (?, ?, ?, ?)});

        my $sth_remove_mapping = $dbh->prepare(
            qq{DELETE FROM user_group_map
               WHERE user_id = ? AND group_id = ?});

        my $user = $result->{user};
        my @ldap_group_dns = @{ $params->{ldap_group_dns} || [] };
        my $qmarks = join(',', ('?') x @ldap_group_dns);
        my $group_ids = $dbh->selectcol_arrayref(
            "SELECT id FROM groups WHERE ldap_dn IN ($qmarks)", undef,
            @ldap_group_dns);

        my @user_group_ids;
        foreach my $group (@{ $user->groups || [] }) {
            push @user_group_ids, $group->id if defined $group->ldap_dn;
        }

        my ($removed, $added) = diff_arrays(\@user_group_ids, \@$group_ids);

        $sth_add_mapping->execute($user->id, $_, 0, GRANT_LDAP)
            foreach @{ $added || [] };

        $sth_remove_mapping->execute($user->id, $_)
            foreach @{ $removed || [] };

        # Clear the cache if there were any group changes
        if (scalar @{ $added } != 0 || scalar @{ $removed } != 0) {
            Bugzilla->memcached->clear_config({ key => 'user_groups.' . $user->id });
        }
    }

    return $result;
}

sub _group_update {
    my ($self, $params) = @_;
    $self->set('ldap_dn', Bugzilla->input_params->{ldap_dn});
    return $self->_orig_update($params);
}

sub _group_create {
    my ($class, $params) = @_;
    $params->{ldap_dn} = scalar Bugzilla->input_params->{ldap_dn};
    return $class->_orig_create($params);
}

sub install_update_db {
    my ($self, $args) = @_;
    my $dbh = Bugzilla->dbh;

    $dbh->bz_add_column('groups', 'ldap_dn',
        { TYPE => 'MEDIUMTEXT', DEFAULT => "''" });
}

sub auth_verify_methods {
    my ($self, $args) = @_;
    my $modules = $args->{modules};
    if (exists $modules->{LDAP}) {
        $modules->{LDAP} =
            'Bugzilla/Extension/LDAPGroups/Auth/Verify/LDAP.pm';
    }
}

sub object_update_columns {
    my ($self, $args) = @_;
    my ($object, $columns) = @$args{qw(object columns)};

    if ($object->isa('Bugzilla::Group')) {
        push (@$columns, 'ldap_dn');
    }
}

sub object_columns {
    my ($self, $args) = @_;

    my ($class, $columns) = @$args{qw(class columns)};

    if ($class->isa('Bugzilla::Group')) {
        push @$columns, qw(ldap_dn);
    }
}

sub object_validators {
    my ($self, $args) = @_;
    my ($class, $validators) = @$args{qw(class validators)};

    if ($class->isa('Bugzilla::Group')) {
        $validators->{ldap_dn} = \&_check_ldap_dn;
    }
}

sub _check_ldap_dn {
    my ($invocant, $ldap_dn, undef, $params) = @_;
    my $ldap = Bugzilla->ldap;

    bind_ldap_for_search();

    $ldap_dn = clean_text($ldap_dn);

    # LDAP DN is optional, but we must validate it if it was
    # passed.
    return if !$ldap_dn;

    # We just want to check if the dn is valid.
    # 'filter' can't be empty neither omitted.
    my $dn_result = $ldap->search(( base   => $ldap_dn,
                                    scope  => 'sub',
                                    filter => '1=1' ));
    if ($dn_result->code) {
        ThrowUserError('group_ldap_dn_invalid', { ldap_dn => $ldap_dn });
    }

    # Group LDAP DN already in use.
    my ($group) = @{ Bugzilla::Group->match({ ldap_dn => $ldap_dn }) };
    my $group_id = blessed($invocant) ? $invocant->id : 0;
    if (defined $group and $group->id != $group_id) {
        ThrowUserError('group_ldap_dn_already_in_use',
            { ldap_dn => $ldap_dn });
    }

    return $ldap_dn;
}

sub group_end_of_create {
    my ($self, $args) = @_;
    my $group = $args->{'group'};
}

sub group_end_of_update {
    my ($self, $args) = @_;
    my ($group, $changes) = @$args{qw(group changes)};
    sync_ldap($group) if $group->ldap_dn;
}

# Add ldap_dn field to the returned data.
sub _group_to_hash {
    my ($self, $params, $group) = @_;
    my $user = Bugzilla->user;

    my $field_data = $self->_orig_group_to_hash($params, $group);
    if ($user->in_group('creategroups')) {
        $field_data->{ldap_dn} = $self->type('string', $group->ldap_dn);
    }

    return $field_data;
}

__PACKAGE__->NAME;
