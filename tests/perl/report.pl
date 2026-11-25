# Reports the perl running it, after loading core modules OpenSSL's perlasm
# scripts and rules_perl's entrypoint need.
use strict;
use warnings;
use bigint;
use Carp qw(croak);
use Cwd ();
use Exporter ();
use File::Spec;
use JSON::PP;

my $big = 2**100;
croak "bigint is not in effect: 2**100 = $big"
  unless "$big" eq "1267650600228229401496703205376";
print JSON::PP->new->canonical->encode(
    {
        exe     => $^X,
        real    => Cwd::realpath( File::Spec->rel2abs($^X) ),
        version => "$]",
    }
  ),
  "\n";
