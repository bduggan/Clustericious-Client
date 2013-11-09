#!/usr/bin/env perl

use lib '.';
use Log::Log4perl qw/:easy/;
Log::Log4perl->easy_init($TRACE);
use tracks;

my $api_key = '12345';

my $t = Tracks->new(server_url => 'http://8tracks.com' );
my $mixes = $t->mixes(
     tags => 'jazz',
     api_key => $api_key,
     per_page => 2,
     ) or die $t->errorstring;
print "Mix : $_->{name}\n" for @{ $mixes->{mixes} };

