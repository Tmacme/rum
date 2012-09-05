package RUM::Script::QuantifyExons;

no warnings;
use RUM::Usage;
use RUM::Logging;
use RUM::QuantMap;
use Getopt::Long;
use RUM::Common qw(roman Roman isroman arabic);
use RUM::Sort qw(cmpChrs);
our $log = RUM::Logging->get_logger();
use strict;
use Data::Dumper;
use Time::HiRes qw(time);

my $START = 3618230;
my $END   = 3618635;

my %STRAND_MAP = (
    p => '+',
    m => '-'
);

sub read_annot_file {
    use strict;
    my ($annotfile, $wanted_strand, $novel) = @_;
    open my $infile, '<', $annotfile;

    # Skip the header row
    <$infile>;
    my %exons_for_chr;

    my $quants = RUM::QuantMap->new;

    while (defined(my $line = <$infile>)) {
        chomp($line);

        my ($loc, $type) = split /\t/, $line;

        if ($novel && $type eq "annotated") {
            next;
        } 

        $loc =~ /^(.*):(\d+)-(\d+)$/ or die "Unexpected input : $line";
        my ($chr, $start, $end) = ($1, $2, $3);
        $quants->add_feature(
            chromosome => $chr,
            start => $start,
            end => $end,
            data => {
                Ucount => 0, NUcount => 0
            });
        push @{ $exons_for_chr{$chr} }, { start => $start, end => $end };
    }

    $quants->partition;

    return (\%exons_for_chr, $quants);

}

sub read_rum_file {
    use strict;

    my %NUREADS;
    my $UREADS=0;


    my ($filename, $type, $wanted_strand, $anti, $quants) = @_;
    open(INFILE, $filename) or die "ERROR: in script rum2quantifications.pl: cannot open '$filename' for reading.\n\n";

    my $counter=0;
    my $line;

    my $start = time;

    while (defined (my $line = <INFILE>)) {
        chomp($line);
        $counter++;

        if ($counter % 10000 == 0) {
            my $end = time;
            printf "%10s: %10d, %f\n", $type, $counter,  ($end - $start) / 10000;
            $start = time;
        }

        my ($readid, $CHR, $locs, $strand) = split /\t/, $line;
            
        $readid =~ /(\d+)/;
        my $seqnum1 = $1;
        if ($type eq "NUcount") {
            $NUREADS{$seqnum1}=1;
        } else {
            $UREADS++;
        }
        if ($wanted_strand) {
            my $same_strand = $STRAND_MAP{$wanted_strand} eq $strand;
            if ($anti) {
                next if $same_strand;
            }
            else {
                next if !$same_strand;
            }
        }

        my @a_spans = map { split /-/ } split /, /, $locs;

        my $line2 = <INFILE>;
        chomp($line2);
        my @b = split /\t/, $line2;
        my ($b_readid, undef, $b_locs) = @b;
        $b_readid =~ /(\d+)/;
        my $seqnum2 = $1;
	
        my @read_spans;

        if ($seqnum1 == $seqnum2 && 
            $b_readid =~ /b/ &&
            $readid   =~ /a/) {

            my @b_spans = map { split /-/ } split /, /, $b_locs;

            if ($strand eq "+") {
                @read_spans = (@a_spans, @b_spans);
            } else {
                @read_spans = (@b_spans, @a_spans);
            }

        } else {

            # reset the file handle so the last line read will be read again
            my $len = -1 * (1 + length($line2));
            seek(INFILE, $len, 1);
            @read_spans = @a_spans;
        }

        my @new_spans;
        for (my $i = 0; $i < @read_spans; $i += 2) {
            push @new_spans, [ $read_spans[$i], 
                               $read_spans[$i+1] ];
        }

        my $covered = $quants->covered_features(
            chromosome => $CHR,
            spans => \@new_spans);
        
        for my $feature (@{ $covered }) {
            $feature->{data}{$type}++;
        }
    }

    return $UREADS || (scalar keys %NUREADS);
    
}

sub main {

    my @A;
    my @B;
    
    GetOptions(
        "exons-in=s"      => \(my $annotfile),    
        "unique-in=s"     => \(my $U_readsfile),
        "non-unique-in=s" => \(my $NU_readsfile),
        "output|o=s"      => \(my $outfile1),
        "info=s"          => \(my $infofile),
        "strand=s"        => \(my $wanted_strand),
        "anti"            => \(my $anti),
        "countsonly"      => \(my $countsonly),
        "novel"           => \(my $novel),
        "help|h"          => sub { RUM::Usage->help },
        "verbose|v"       => sub { $log->more_logging(1) },
        "quiet|q"         => sub { $log->less_logging(1) });
    
    $annotfile or RUM::Usage->bad(
        "Please specify an exons file with --exons-in");
    $U_readsfile or RUM::Usage->bad(
        "Please specify a RUM_Unique file with --unique-in");
    $NU_readsfile or RUM::Usage->bad(
        "Please specify a RUM_NU file with --non-unique-in");
    $outfile1 or RUM::Usage->bad(
        "Please specify an output file with -o or --output");

    if ($wanted_strand) {
        $wanted_strand eq 'p' || $wanted_strand eq 'm' or RUM::Usage->bad(
            "--strand must be p or m, not $wanted_strand");
    }

    # read in the transcript models
    my ($EXON, $quants) = read_annot_file($annotfile, $wanted_strand, $novel);

    my $num_reads = read_rum_file($U_readsfile,   "Ucount", $wanted_strand, $anti, $quants);
    $num_reads   += read_rum_file($NU_readsfile, "NUcount", $wanted_strand, $anti, $quants);

    open my $outfile, '>', $outfile1;

    if ($countsonly) {
        print $outfile "num_reads = $num_reads\n";
    }

    foreach my $chr (sort {cmpChrs($a,$b)} keys %{ $quants->{quants_for_chromosome}}) {

        my $features = $quants->features(chromosome => $chr);
        my @features = sort { 
            $a->{start} <=> $b->{start} ||
            $a->{end}   <=> $b->{start} 
        } @{ $features };
       
        for my $exon ( @features) { 
            my $x1 = $exon->{data}{Ucount}  || 0;
            my $x2 = $exon->{data}{NUcount} || 0;
            my $s  = $exon->{start}   || 0;
            my $e  = $exon->{end}     || 0;
            my $elen = $e - $s + 1;
            
            print $outfile "exon\t$chr:$s-$e\t$x1\t$x2\t$elen\n";

        }
    }


}



sub do_they_overlap() {

    my ($exon_span, $B) = @_;

    my $i = 0;
    my $j = 0;
    
    while (1) {

      EXON_EVENT: while (1) {

            if ($i % 2) {
                my $exon_end   = $exon_span->[$i];
                last EXON_EVENT if $B->[$j] <= $exon_end;
            }
            else {
                my $exon_start =  $exon_span->[$i];
                last EXON_EVENT if $B->[$j] < $exon_start;
            }
            
            $i++;
            if ($i == @$exon_span) {
                return $B->[$j] == $exon_span->[@$exon_span - 1];
            }
        }

        # At an exon end
        if ($i % 2) {
            return 1;
        } 
        
        else {
            $j++;

            my $exon_start = $exon_span->[$i];
            my $at_read_end = $j % 2;

            if ($at_read_end && $exon_start <= $B->[$j]) {
                return 1;
            }

            # Past all the reads
            if ($j >= @$B) {
                return 0;
            }
        }
    }
}

1;


