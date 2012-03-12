#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 9;
use FindBin qw($Bin);
use File::Copy;
use lib "$Bin/../lib";
use RUM::Script::RumToSam;
use RUM::TestUtils;

my $unique_in     = "$INPUT_DIR/RUM_Unique.1";
my $non_unique_in = "$INPUT_DIR/RUM_NU.1";
my $reads_in      = "$INPUT_DIR/reads.fa.1";
my $quals_in      = "$INPUT_DIR/quals.fa.1";

my %configs = (
    u_nu_quals => [$unique_in, $non_unique_in, $reads_in, $quals_in],
    nu_quals   => ["none",     $non_unique_in, $reads_in, $quals_in],
    u_quals    => [$unique_in, "none",         $reads_in, $quals_in],
    u_nu       => [$unique_in, $non_unique_in, $reads_in, undef],
    nu         => ["none",     $non_unique_in, $reads_in, undef],
    u          => [$unique_in, "none",         $reads_in, undef],
);


while (my ($name, $args) = each %configs) {
    my ($unique, $non_unique, $reads, $quals) = @$args;
    my $out = temp_filename(TEMPLATE => "$name-XXXXXX");

    @ARGV = ($unique, $non_unique, "--sam-out", $out);
    push @ARGV, "--quals-in", $quals if $quals;
    push @ARGV, "--reads-in", $reads if $reads;
    RUM::Script::RumToSam->main();
    no_diffs($out, "$EXPECTED_DIR/$name.sam", $name);
}

for my $suppress (1, 2, 3) {
    
    my $name = "suppress$suppress";
    my $out = temp_filename(TEMPLATE => "$name-XXXXXX");
    @ARGV = ($unique_in, $non_unique_in,
             "--reads-in", $reads_in,
             "--sam-out", $out, 
             "--quals-in", $quals_in,
             "--suppress$suppress");
    RUM::Script::RumToSam->main();
    no_diffs($out, "$EXPECTED_DIR/$name.sam", $name);
}