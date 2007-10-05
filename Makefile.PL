use inc::Module::Install 0.65;

name 'Catalyst-Plugin-Session-Store-DBI';
all_from 'lib/Catalyst/Plugin/Session/Store/DBI.pm';

requires 'Catalyst::Runtime'         => '5.49';
requires 'Catalyst::Plugin::Session' => '0.05';
requires 'DBI';
requires 'MIME::Base64';
requires 'Storable';
requires 'Test::More';

auto_install;
WriteAll;
