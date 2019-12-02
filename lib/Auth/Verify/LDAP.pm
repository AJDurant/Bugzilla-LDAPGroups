# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::LDAPGroups::Auth::Verify::LDAP;
use strict;
use parent qw(Bugzilla::Auth::Verify::LDAP);

use Bugzilla::Error qw(ThrowCodeError);

use Net::LDAP::Util qw(escape_filter_value);


sub check_credentials {
    my ($self, $params) = @_;
    $params = $self->SUPER::check_credentials($params);
    return $params if $params->{failure};
    my $ldap_group_dns = $self->_ldap_member_of_groups($params->{bz_username});
    $params->{ldap_group_dns} = $ldap_group_dns if scalar @$ldap_group_dns;
    return $params;
}

sub _ldap_member_of_groups {
    my ($self, $uid) = @_;

    $uid = escape_filter_value($uid);
    my $uid_attr = Bugzilla->params->{"LDAPuidattribute"};
    my $mail_attr = Bugzilla->params->{"LDAPmailattribute"};
    my $base_dn = Bugzilla->params->{"LDAPBaseDN"};

    # Find the immediate groups the user is a member of.
    my $dn_result = $self->ldap->search(( base   => $base_dn,
                                          scope  => 'sub',
                                          filter => "$uid_attr=$uid" ),
                                          attrs => ['memberof', 'distinguishedName']);

    if ($dn_result->code) {
        ThrowCodeError('ldap_search_error',
            { errstr => $dn_result->error, username => $uid });
    }

    my @dns;
    push @dns, $_->get_value('distinguishedName') for $dn_result->entries;
    my $user_dn = @dns[0];
    $user_dn = escape_filter_value($user_dn);

    my @ldap_group_dns;
    push @ldap_group_dns, $_->get_value('memberof') for $dn_result->entries;

    # Find all of the leaf groups the user is a member of.
    # This is specific to Active Directory and it only works with DNs.
    # 1.2.840.113556.1.4.1941 = LDAP_MATCHING_RULE_IN_CHAIN
    # https://msdn.microsoft.com/en-us/library/aa746475(v=vs.85).aspx
    my $groups_result = $self->ldap->search(( base   => $base_dn,
                                              scope  => 'sub',
                                              filter => "member:1.2.840.113556.1.4.1941:=$user_dn" ),
                                              attrs => ['memberof']);

    if ($groups_result->code) {
        ThrowCodeError('ldap_search_error',
            { errstr => $dn_result->error, username => $uid });
    }

    push @ldap_group_dns, $_->get_value('memberof') for $groups_result->entries;

    return \@ldap_group_dns;
}

1;
