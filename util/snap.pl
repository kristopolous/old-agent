#!/usr/bin/env perl
# snap.pl [title-substring] [outfile.png]
#   default outfile: /tmp/oa-snap.png
#   captures the whole X screen (:0) and, if a title is given, tries to
#   crop to the matching window. prints the output path on the last line.
use strict;
use warnings;
my $title = shift @ARGV;
my $out   = shift @ARGV || '/tmp/oa-snap.png';
my $disp  = $ENV{DISPLAY} || ':0';

my $tmp_raw = "/tmp/oa-snap-$$.xwd";
system("xwd", "-display", $disp, "-root", "-silent", "-out", $tmp_raw) == 0
    or do { print "xwd failed\n"; exit 1 };
# xwd -> pnm -> png (ImageMagick); also grab window geometry if we want a crop
my $png_ok = system("xwdtopnm $tmp_raw > /tmp/oa-snap-$$.pnm") == 0
    && system("convert /tmp/oa-snap-$$.pnm $out") == 0;
unlink $tmp_raw, "/tmp/oa-snap-$$.pnm";
if (!$png_ok) { print "convert failed\n"; exit 1 }

# if a title was given, try to crop to that window's geometry via xdotool
if (defined $title && length $title) {
    my $win = `DISPLAY=$disp xdotool search --name "$title" 2>/dev/null | head -1`;
    chomp $win; $win =~ s/\s+$//;
    if (length $win) {
        my $geo = `DISPLAY=$disp xdotool getwindowgeometry $win 2>/dev/null`;
        if ($geo =~ /Position:\s+(\d+),\s*(\d+)\s+.*?Window size:\s*(\d+)x(\d+)/s) {
            my ($x, $y, $w, $h) = ($1, $2, $3, $4);
            my $crop = "$out.crop.png";
            system("convert", $out, "-crop", "${w}x${h}+${x}+${y}", "+repage", $crop) == 0
                && rename($crop, $out);
        }
    }
}
print $out, "\n";
