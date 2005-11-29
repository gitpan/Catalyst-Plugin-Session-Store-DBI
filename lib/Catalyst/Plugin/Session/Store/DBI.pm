package Catalyst::Plugin::Session::Store::DBI;

use strict;
use warnings;
use base qw/Class::Data::Inheritable Catalyst::Plugin::Session::Store/;
use DBI;
use MIME::Base64;
use NEXT;
use Storable qw/nfreeze thaw/;

our $VERSION = '0.02';

__PACKAGE__->mk_classdata('_session_dbh');

sub get_session_data {
    my ( $c, $sid ) = @_;

    my $table = $c->config->{session}->{dbi_table};
    my $sth   =
      $c->_session_dbh->prepare_cached(
        "SELECT session_data FROM $table WHERE id = ?");
    $sth->execute($sid);
    my ($session) = $sth->fetchrow_array;
    $sth->finish;
    if ($session) {
        return thaw( decode_base64($session) );
    }
    return;
}

sub store_session_data {
    my ( $c, $sid, $session ) = @_;

    my $table = $c->config->{session}->{dbi_table};

    # check for existing record
    my $sth =
      $c->_session_dbh->prepare_cached("SELECT 1 FROM $table WHERE id = ?");
    $sth->execute($sid);
    my ($exists) = $sth->fetchrow_array;
    $sth->finish;

    # update or insert as needed
    my $sql =
      ($exists)
      ? "UPDATE $table SET session_data = ?, expires = ? WHERE id = ?"
      : "INSERT INTO $table (session_data, expires, id) VALUES (?, ?, ?)";
    my $sta    = $c->_session_dbh->prepare_cached($sql);
    my $frozen = encode_base64( nfreeze($session) );
    $sta->execute( $frozen, $session->{__expires}, $sid );

    return;
}

sub delete_session_data {
    my ( $c, $sid ) = @_;

    my $table = $c->config->{session}->{dbi_table};
    my $sth   = $c->_session_dbh->prepare("DELETE FROM $table WHERE id = ?");
    $sth->execute($sid);

    return;
}

sub delete_expired_sessions {
    my $c = shift;

    my $table = $c->config->{session}->{dbi_table};
    my $sth = $c->_session_dbh->prepare("DELETE FROM $table WHERE expires < ?");
    $sth->execute(time);

    return;
}

sub setup_session {
    my $c = shift;

    $c->NEXT::setup_session(@_);

    $c->config->{session}->{dbi_table} ||= 'sessions';
    my $cfg = $c->config->{session};

    if ( $cfg->{dbi_dsn} ) {
        my @dsn = grep { defined $_ } @{$cfg}{qw/dbi_dsn dbi_user dbi_pass/};
        my $dbh = DBI->connect_cached(
            @dsn,
            {
                AutoCommit => 1,
                RaiseError => 1,
            }
          )
          or Catalyst::Exception->throw( message => $DBI::errstr );
        $c->_session_dbh($dbh);
    }
}

sub setup_actions {
    my $c = shift;

    $c->NEXT::setup_actions(@_);

    # DBIC/CDBI classes are not yet loaded during setup(), so we wait until
    # setup_actions to load them

    my $cfg = $c->config->{session};

    if ( $cfg->{dbi_dbh} ) {
        if ( ref $cfg->{dbi_dbh} ) {

            # use an existing db handle
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
                          . "Class::DBI model; $@" );
                }
            }
            $c->_session_dbh($dbh);
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
        id           char(40) primary key,
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
the delete_expired_sessions method to perform clean up.

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

Your session table must contain at minimum the following 3 columns:

    id           CHAR(40) PRIMARY KEY
    session_data TEXT
    expires      INT(10)

Session IDs are generated using SHA-1 by default and are therefore 40
characters long.

The session_data field should be a long text field.  Session data is encoded
using Base64 before being stored in the database.

=head1 METHODS

=head2 get_session_data

=head2 store_session_data

=head2 delete_session_data

=head2 delete_expired_sessions

=head2 setup_session

These are implementations of the required methods for a store. See
L<Catalyst::Plugin::Session::Store>.

=head1 INTERNAL METHODS

=head2 setup_actions

=head1 SEE ALSO

L<Catalyst>, L<Catalyst::Plugin::Session>

=head1 AUTHOR

Andy Grundman, <andy@hybridized.org>

=head1 COPYRIGHT

This program is free software, you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
