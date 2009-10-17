package TestApp;

use strict;
use Catalyst;
use FindBin;

our $VERSION = '0.01';

our $db_file = "$FindBin::Bin/tmp/session.db";
__PACKAGE__->config(
    name    => __PACKAGE__,
    'Plugin::Session' => {
        expires => 3600,
        dbi_dsn => "dbi:SQLite:$db_file",
    }
);

__PACKAGE__->setup(qw/Session Session::Store::DBI Session::State::Cookie/);

1;
