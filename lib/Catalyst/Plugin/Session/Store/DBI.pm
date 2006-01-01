package Catalyst::Plugin::Session::Store::DBI;

use strict;
use warnings;
use base qw/Class::Data::Inheritable Catalyst::Plugin::Session::Store/;
use DBI;
use MIME::Base64;
use NEXT;
use Storable qw/nfreeze thaw/;

our $VERSION = '0.05';

__PACKAGE__->mk_classdata('_session_dbh');
__PACKAGE__->mk_classdata('_sth_get_session_data');
__PACKAGE__->mk_classdata('_sth_get_expires');
__PACKAGE__->mk_classdata('_sth_check_existing');
__PACKAGE__->mk_classdata('_sth_update_session');
__PACKAGE__->mk_classdata('_sth_insert_session');
__PACKAGE__->mk_classdata('_sth_update_expires');
__PACKAGE__->mk_classdata('_sth_delete_session');
__PACKAGE__->mk_classdata('_sth_delete_expired_sessions');

sub get_session_data {
    my ( $c, $key ) = @_;
    
    # expires:sid expects an expiration time
    if ( my ($sid) = $key =~ /^expires:(.*)/ ) {
        $key = "session:$sid";
        my $sth = $c->_session_sth('get_expires');
        $sth->execute($key);
        my ($expires) = $sth->fetchrow_array;
        return $expires;
    }
    else {
        my $sth = $c->_session_sth('get_session_data');
        $sth->execute($key);
        if ( my ($data) = $sth->fetchrow_array ) {
            return thaw( decode_base64($data) );
        }
    }
    return;
}

sub store_session_data {
    my ( $c, $key, $data ) = @_;
    
    # expires:sid keys only update the expiration time
    if ( my ($sid) = $key =~ /^expires:(.*)/ ) {
        $key = "session:$sid";
        my $sth = $c->_session_sth('update_expires');
        $sth->execute( $c->session_expires, $key );
    }
    else {
        # check for existing record
        my $sth = $c->_session_sth('check_existing');
        $sth->execute($key);
        my ($exists) = $sth->fetchrow_array;
    
        # update or insert as needed
        my $sta = ($exists)
            ? $c->_session_sth('update_session')
            : $c->_session_sth('insert_session');

        my $frozen = encode_base64( nfreeze($data) );
        my $expires = $key =~ /^(?:session|flash):/ 
                    ? $c->session_expires 
                    : undef;
        $sta->execute( $frozen, $expires, $key );
    }
    
    return;
}

sub delete_session_data {
    my ( $c, $key ) = @_;
    
    return if $key =~ /^expires/;

    my $sth = $c->_session_sth('delete_session');
    $sth->execute($key);

    return;
}

sub delete_expired_sessions {
    my $c = shift;

    my $sth = $c->_session_sth('delete_expired_sessions');
    $sth->execute(time);

    return;
}

sub prepare {
    my $c = shift;

    my $cfg = $c->config->{session};

    # If using DBIC/CDBI, always grab their dbh
    if ( $cfg->{dbi_dbh} ) {
        $c->_session_dbic_connect();
    }
    else {
        # make sure the database is still connected
        eval { $c->_session_dbh->ping };
        if ($@) {
            # reconnect
            $c->_session_dbi_connect();
        }
    }

    $c->NEXT::prepare(@_);
}

sub setup_session {
    my $c = shift;

    $c->NEXT::setup_session(@_);

    $c->config->{session}->{dbi_table} ||= 'sessions';
}

sub _session_dbi_connect {
    my $c = shift;

    my $cfg = $c->config->{session};

    if ( $cfg->{dbi_dsn} ) {
        my @dsn = grep { defined $_ } @{$cfg}{qw/dbi_dsn dbi_user dbi_pass/};
        my $dbh = DBI->connect(
            @dsn,
            {   AutoCommit => 1,
                RaiseError => 1,
            }
        ) or Catalyst::Exception->throw( message => $DBI::errstr );
        $c->_session_dbh($dbh);
    }
}

sub _session_dbic_connect {
    my $c = shift;

    my $cfg = $c->config->{session};

    if ( $cfg->{dbi_dbh} ) {
        if ( ref $cfg->{dbi_dbh} ) {

            # use an existing db handle
            if ( !$cfg->{dbi_dbh}->{Active} ) {
                Catalyst::Exception->throw( message =>
                        'Session: Database handle supplied is not active' );
            }
            $c->_session_dbh( $cfg->{dbi_dbh} );
        }
        else {

            # use a DBIC/CDBI class
            my $class = $cfg->{dbi_dbh};
            my $dbh;
            eval { $dbh = $class->storage->dbh };
            if ($@) {
                eval { $dbh = $class->db_Main };
                if ($@) {
                    Catalyst::Exception->throw( message =>
                              "$class does not appear to be a DBIx::Class or "
                            . "Class::DBI model: $@" );
                }
            }
            $c->_session_dbh($dbh);
        }
    }
}

# Prepares SQL statements as needed
sub _session_sth {
    my ( $c, $key ) = @_;

    my $table = $c->config->{session}->{dbi_table};

    my %sql = (
        get_session_data        =>
            "SELECT session_data FROM $table WHERE id = ?",
        get_expires             =>
            "SELECT expires FROM $table WHERE id = ?",
        check_existing          =>
            "SELECT 1 FROM $table WHERE id = ?",
        update_session          =>
            "UPDATE $table SET session_data = ?, expires = ? WHERE id = ?",
        insert_session          =>
            "INSERT INTO $table (session_data, expires, id) VALUES (?, ?, ?)",
        update_expires          =>
            "UPDATE $table SET expires = ? WHERE id = ?",
        delete_session          =>
            "DELETE FROM $table WHERE id = ?",
        delete_expired_sessions =>
            "DELETE FROM $table WHERE expires IS NOT NULL AND expires < ?",
    );

    if ( $sql{$key} ) {
        my $accessor = "_sth_$key";
        if ( !defined $c->$accessor ) {
            $c->$accessor( $c->_session_dbh->prepare( $sql{$key} ) );
        }
        return $c->$accessor;
    }
    return;
}

# close any active sth's to avoid warnings
sub DESTROY {
    my $c = shift;
    $c->NEXT::DESTROY(@_);

    my @handles = qw/
        get_session_data
        get_expires
        check_existing
        update_session
        insert_session
        update_expires
        delete_session
        delete_expired_sessions/;

    for my $key (@handles) {
        my $accessor = "_sth_$key";
        if ( defined $c->$accessor && $c->$accessor->{Active} ) {
            $c->$accessor->finish;
        }
    }
}

1;
__END__

=head1 NAME

Catalyst::Plugin::Session::Store::DBI - Store your sessions in a database

=head1 SYNOPSIS

    # Create a table in your database for sessions
    CREATE TABLE sessions (
        id           char(72) primary key,
        session_data text,
        expires      int(10)
    );

    # In your app
    use Catalyst qw/Session Session::Store::DBI Session::State::Cookie/;
    
    # Connect directly to the database
    MyApp->config->{session} = {
        expires   => 3600,
        dbi_dsn   => 'dbi:mysql:database',
        dbi_user  => 'foo',
        dbi_pass  => 'bar',
        dbi_table => 'sessions',
    };
    
    # Or use an existing database handle from a DBIC/CDBI class
    MyApp->config->{session} = {
        expires   => 3600,
        dbi_dbh   => 'MyApp::M::DBIC',
        dbi_table => 'sessions',
    };

    # ... in an action:
    $c->session->{foo} = 'bar'; # will be saved

=head1 DESCRIPTION

This storage module will store session data in a database using DBI.

=head1 CONFIGURATION

These parameters are placed in the configuration hash under the C<session>
key.

=head2 expires

The expires column in your table will be set with the expiration value.
Note that no automatic cleanup is done on your session data, but you can use
the delete_expired_sessions method to perform clean up.  You can make use of
the L<Catalyst::Plugin::Scheduler> plugin to schedule automated session
cleanup.

=head2 dbi_dbh

Pass in an existing $dbh or the class name of a L<DBIx::Class>
or L<Class::DBI> model.  This method is recommended if you have other
database code in your application as it will avoid opening additional
connections.

=head2 dbi_dsn

=head2 dbi_user

=head2 dbi_pass

To connect directly to a database, specify the necessary dbi_dsn, dbi_user,
and dbi_pass options.

=head2 dbi_table

Enter the table name within your database where sessions will be stored.
This table must have at least 3 columns, id, session_data, and expires.
See the Schema section below for additional details.  The table name defaults
to 'sessions'.

=head1 SCHEMA

Your 'sessions' table must contain at minimum the following 3 columns:

    id           char(72) primary key
    session_data text
    expires      int(10)

The 'id' column should probably be 72 characters. It needs to handle the
longest string that can be returned by
L<Catalyst::Plugin::Authentication/generate_session_id>, plus another 8
characters for internal use. This is less than 72 characters in practice when
SHA-1 or MD5 are used, but SHA-256 will need all those characters.

The 'session_data' column should be a long text field.  Session data is
encoded using Base64 before being stored in the database.

The 'expires' column stores the future expiration time of the session.  This
may be null for per-user and flash sessions.

=head1 METHODS

=head2 get_session_data

=head2 store_session_data

=head2 delete_session_data

=head2 delete_expired_sessions

=head2 setup_session

These are implementations of the required methods for a store. See
L<Catalyst::Plugin::Session::Store>.

=head1 INTERNAL METHODS

=head2 prepare

=head2 setup_actions

=head1 SEE ALSO

L<Catalyst>, L<Catalyst::Plugin::Session>, L<Catalyst::Plugin::Scheduler>

=head1 AUTHOR

Andy Grundman, <andy@hybridized.org>

=head1 COPYRIGHT

This program is free software, you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
