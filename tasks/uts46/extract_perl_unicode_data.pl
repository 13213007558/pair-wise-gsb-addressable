use strict;
use warnings;
use Unicode::UCD qw(prop_invlist all_casefolds);

# Dumps Bidi_Class, Joining_Type, Canonical_Combining_Class=9 ranges and
# full case foldings from the Perl core Unicode data (offline).
#
# Usage: perl tasks/uts46/extract_perl_unicode_data.pl [output_dir]

my $outdir = $ARGV[0] || "tmp/uts46";

sub dump_invlist {
    my ($file, $prop, @values) = @_;
    open(my $fh, ">", "$outdir/$file") or die $!;
    for my $v (@values) {
        my @inv = prop_invlist("$prop=$v");
        die "no data for $prop=$v" unless @inv;
        for (my $i = 0; $i < @inv; $i += 2) {
            my $start = $inv[$i];
            my $end = defined $inv[$i + 1] ? $inv[$i + 1] - 1 : 0x10FFFF;
            print $fh "$v $start $end\n";
        }
    }
    close($fh);
}

dump_invlist("perl_bidi.txt", "Bidi_Class",
    qw(L R AL EN ES ET AN CS BN B S WS ON NSM LRE LRO RLE RLO PDF LRI RLI FSI PDI));
dump_invlist("perl_jt.txt", "Joining_Type", qw(U L R D T C));

open(my $fh, ">", "$outdir/perl_ccc9.txt") or die $!;
my @inv = prop_invlist("Canonical_Combining_Class=9");
for (my $i = 0; $i < @inv; $i += 2) {
    my $start = $inv[$i];
    my $end = defined $inv[$i + 1] ? $inv[$i + 1] - 1 : 0x10FFFF;
    print $fh "$start $end\n";
}
close($fh);

open($fh, ">", "$outdir/perl_casefolds.txt") or die $!;
my $casefolds = all_casefolds();
for my $cp (sort { $a <=> $b } keys %$casefolds) {
    my $e = $casefolds->{$cp};
    print $fh sprintf("%x %s %s\n", $cp, $e->{simple} || "-", $e->{full} || "-");
}
close($fh);
print "wrote dumps to $outdir\n";
