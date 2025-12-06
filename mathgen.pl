#!/usr/bin/perl -w

#    mathgen.pl: main driver code
#
#    Copyright (C) 2012  Nathaniel Eldredge
#    This file is part of Mathgen.
#
#    Mathgen is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    Mathgen is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with Mathgen; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use scigen;
use Getopt::Long;
use File::Temp qw { tempdir };
use Cwd;
use File::Spec;
use File::Path qw(make_path);
use File::Copy qw(copy);

my $default_mode = 'view';
my $default_viewer = 'evince';
my $default_product = 'article';

my %modes = map {$_ => 1} qw { pdf zip dir view raw };
my %products = (
    'article' => { PRETTY => 'latex' },
    'book' => { PRETTY => 'latexbook' },
    'blurb' => { PRETTY => 0 }
    );

my $bibname = "scigenbibfile.bib";

my $data_dir = '.';

my @authors;
my $custom_title;  # Optional custom title
my $mode = $default_mode; # pdf, zip, dir, view, raw (undocumented)
my $viewer = $default_viewer;
my $dir;
my $output;
my $product = $default_product;
my $seed;
my $debug = 0;
my @topics;  # Topic(s) to bias the generated content toward

# Bibliography options
my $bib_include_author = 1;  # Include paper's author in references
my $bib_famous = 'all';      # all, topic, or none

my %options;

my $output_fh;

my $rules = {};
my $rules_RE = undef;
my $orig_cwd = Cwd::getcwd();

sub readme_text {
    my ($p, $basename) = @_;
    my $t;
    if ($p eq 'article') {
	$t = <<"EOF";
To recompile this file, run:

pdflatex $basename
bibtex $basename
pdflatex $basename
pdflatex $basename

You need the following packages installed:

AMS-LaTeX
fullpage
mathrsfs
natbib
truncate
EOF
	; # fix indentation for emacs
    } elsif ($p eq 'book') {
	$t =  <<"EOF";
To recompile this file, run:

pdflatex $basename
bibtex $basename
makeindex $basename.idx
pdflatex $basename
pdflatex $basename

You need the following packages installed:

AMS-LaTeX
geometry
mathrsfs
natbib
txfonts
hyphenat
textcase
hyperref
truncate
titlesec
makeidx
url
tocbibind

The output is set to 6x9 inch paper and is suitable for lulu.com.
EOF
	;
    }
    return $t;
}

sub usage {
    select(STDERR);
    print <<EOUsage;
    
$0 [options]
  Options:

    --help                    Display this help message
    --author=<quoted_name>    An author of the paper (can be specified
                              multiple times)
                              Default: One random author
    --title=<quoted_title>    Custom title for the paper/book
                              Default: Randomly generated title
    --mode=pdf|zip|dir|view|raw
                              What to output
    	   		      pdf: Output a PDF file
			      zip: Output a zip file with 
			      	   LaTeX/BiBTeX source and PDF
			      dir: Leave source and PDF in directory
			       	   specified with --dir
			      view: Invoke viewer on PDF file
			      raw: Output raw tex/txt only (required for blurb)
    --viewer=<prog>	      Use <prog> as PDF viewer (default: $default_viewer)
    --dir=<dir>		      For --mode=dir: use <dir> for output
    --output=<file>	      For --mode=pdf,zip,raw: Output to <file>
    	     		      Use - for stdout
    --product=article|book|blurb
                              What to generate (default: $default_product)
    --seed=<seed>             Use <seed> to seed the PRNG
    --topic=<topic>           Topic to bias content toward (can be specified
                              multiple times for combined topics)
                              Available: topology, algebra, analysis,
                              probability, number_theory, social_choice,
                              approval_voting
    --bib-include-author      Include paper's author in references (default: true)
    --no-bib-include-author   Exclude paper's author from references
    --bib-famous=all|topic|none
                              How to include famous mathematicians in references
                              all: Use all famous mathematicians (default)
                              topic: Only use topic-specific famous names
                              none: Don't use famous mathematicians
    --debug                   Enable various debugging features
EOUsage
    exit(1);

}

sub parse_options {
    GetOptions( \%options, 
		"help|?" => \&usage,
		"author=s@" => \@authors, 
		"title=s" => \$custom_title,
		"mode=s" => \$mode,
		"viewer=s" => \$viewer,
		"dir=s" => \$dir,
		"output=s" => \$output,
		"product=s" => \$product,
		"seed=i" => \$seed,
		"topic=s@" => \@topics,
		"bib-include-author!" => \$bib_include_author,
		"bib-famous=s" => \$bib_famous,
		"debug!" => \$debug)
	or usage();

    # Validate bib-famous option
    if ($bib_famous !~ /^(all|topic|none)$/) {
	printf STDERR "$0: Unknown bib-famous value '$bib_famous'. Use all, topic, or none.\n";
	usage();
    }
    if (!$modes{$mode}) {
	printf STDERR "$0: Unknown mode $mode\n";
	usage();
    }

    if (!$products{$product}) {
	printf STDERR "$0: Unknown product $product\n";
	usage();
    }

    # Blurb mode is a hack because the output is text not tex
    if ($product eq 'blurb' and $mode ne 'raw') {
	printf STDERR "$0: --product=blurb only works with --mode=raw";
	usage();
    }
    
    if (!@authors) { # No author supplied
	@authors = ("AUTHOR"); # random author
    }
}

sub setup_dir {   
    if (!defined($dir)) {
	$dir = tempdir("mathgen.$$.XXXXXXXXXXXXXXXXXXXXXXXX",
		       TMPDIR => 1,
		       CLEANUP => ($debug ? 0 : 1))
	    or die("tempdir: $!");
    }
    chdir($dir) or die("$dir: $!");
}

sub open_output {
    if (defined($output)) {
	if ($output eq '-') {
	    $output_fh = *STDOUT;
	} else {
	    open($output_fh, ">$output")
		or die("$output: $!");
	}
    } else {
	if ($mode eq 'pdf' or $mode eq 'zip' or $mode eq 'raw') {
	    print STDERR "$0: Must specify --output with --mode pdf,zip,raw\n";
	    usage();
	}
    }
}

sub setup_seed {
    if (defined($seed)) {
	srand($seed);
    } else {
	# In 5.14 srand returns seed value
	if (0 and $^V and $^V ge v5.14) { # disabled until it can be tested
	    $seed = srand();
	} else { # backward compatible
	    $seed = int rand 0xffffffff;
	    srand($seed);
	}
	if ($debug) {
	    print STDERR "seed = $seed\n";
	}
    }
}


sub add_author_rules {
    my ($rules) = @_;
    $rules->{"AUTHOR_NAME"} = \@authors;
    my $s = "";
    my @a = @authors;
    my $la = pop(@a);
    if (@a) {
	$s = join(', ', @a) . ' and ';
    }
    $s .= $la;
    $rules->{"SCIAUTHORS"} = [ $s ];
}

sub add_year_rules {
    my ($rules) = @_;
    my @year_rule = ();
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
    my $thisyear = $year + 1900;

    # We wish to have entries for each of the last 100 years, with
    # more recent years being exponentially more likely
    my $nyears = 100;
    my $r = 35; # newest year is this many times more likely than oldest

    foreach my $i (0..$nyears-1) {  # don't use the current year
	my $y = $thisyear - $nyears + $i;
	my $n = $r**($i/$nyears);
	push(@year_rule, ($y) x $n);
    }
    
    $rules->{"SCI_YEAR"} = \@year_rule;
}

sub add_topic_rules {
    my ($rules) = @_;
    
    foreach my $topic (@topics) {
        my $topic_file = "${data_dir}/topics/${topic}.in";
        if (-f $topic_file) {
            my $topic_fh;
            open($topic_fh, "<$topic_file")
                or die("$topic_file: $!");
            scigen::read_rules($topic_fh, $rules, undef, $debug);
            close($topic_fh);
            if ($debug) {
                print STDERR "Loaded topic: $topic\n";
            }
        } else {
            print STDERR "Warning: Topic file not found: $topic_file\n";
            print STDERR "Available topics: topology, algebra, analysis, probability, number_theory, social_choice\n";
        }
    }
    
    # Recompute the regex after adding topic rules
    if (@topics) {
        scigen::compute_re($rules, \$rules_RE);
    }
}

sub add_bibliography_rules {
    my ($rules) = @_;
    
    # Modify AUTHOR rules based on bibliography options
    # The default AUTHOR rule in scirules.in is:
    #   AUTHOR+10 FAMOUS_AUTHOR
    #   AUTHOR+20 GENERIC_AUTHOR
    #   AUTHOR+4 AUTHOR_NAME
    
    my @author_rules = ();
    
    # Handle famous authors option
    if ($bib_famous eq 'none') {
        # No famous authors at all
        if ($debug) {
            print STDERR "Bibliography: excluding all famous authors\n";
        }
    } elsif ($bib_famous eq 'topic') {
        # Only use topic-specific famous authors (if topics are loaded, they
        # already added their FAMOUS entries; we just don't add FAMOUS_AUTHOR)
        if (@topics) {
            # Topics have their own FAMOUS entries; use those via FAMOUS_AUTHOR
            for (1..10) { push @author_rules, 'FAMOUS_AUTHOR'; }
            if ($debug) {
                print STDERR "Bibliography: using topic-specific famous authors only\n";
            }
        } else {
            if ($debug) {
                print STDERR "Bibliography: no topics specified, excluding famous authors\n";
            }
        }
    } else {
        # 'all' - use all famous authors (default behavior)
        for (1..10) { push @author_rules, 'FAMOUS_AUTHOR'; }
    }
    
    # Always include generic authors
    for (1..20) { push @author_rules, 'GENERIC_AUTHOR'; }
    
    # Handle author inclusion in references
    if ($bib_include_author) {
        for (1..4) { push @author_rules, 'AUTHOR_NAME'; }
        if ($debug) {
            print STDERR "Bibliography: including paper author in references\n";
        }
    } else {
        if ($debug) {
            print STDERR "Bibliography: excluding paper author from references\n";
        }
    }
    
    # Override the AUTHOR rule
    $rules->{"AUTHOR"} = \@author_rules;
}

sub setup_rules {

    # Open rule file
    my $rulefile = "${data_dir}/sci${product}.in";
    my $rule_fh;
    open($rule_fh, "<$rulefile")
	or die("$rulefile: $!");
    
    $rules->{"SEED"} = [ $seed ];
    add_author_rules($rules);
    add_year_rules($rules);
    
    scigen::read_rules ($rule_fh, $rules, \$rules_RE, $debug);

    # Load topic-specific rules if any topics were specified
    add_topic_rules($rules);
    
    # Apply bibliography customizations (must be after topics are loaded)
    add_bibliography_rules($rules);
    
    # Override title if custom title was provided (must be after all rules are loaded)
    # Note: We override SCI_TITLE and BTITLE but NOT ATITLE, because ATITLE is also
    # used for generating bibliography entries and we don't want all references to
    # have the same title as the paper.
    if (defined $custom_title && $custom_title ne '') {
        # Clean the title: remove any double backslashes that might have been
        # accidentally included (common when escaping in shells)
        # Replace \\ with a space or just remove it
        my $clean_title = $custom_title;
        $clean_title =~ s/\\\\/ /g;  # Replace \\ with space
        $clean_title =~ s/\s+/ /g;   # Normalize multiple spaces to single space
        $clean_title =~ s/^\s+|\s+$//g;  # Trim leading/trailing spaces
        
        $rules->{"SCI_TITLE"} = [ $clean_title ];
        $rules->{"BTITLE"} = [ $clean_title ];
        if ($debug) {
            print STDERR "Using custom title: $clean_title\n";
            if ($custom_title ne $clean_title) {
                print STDERR "  (cleaned from: $custom_title)\n";
            }
        }
    }
    
    # Recompute regex after all rule modifications
    scigen::compute_re($rules, \$rules_RE);
}

    
sub generate_text {
    return scigen::generate (
	$rules, 'START', $rules_RE, $debug, $products{$product}{PRETTY});
}

sub generate_bibtex;
sub dump_to_file;
sub pdflatex;
sub bibtex;
sub makeindex;
sub output_filespec;
sub dump_to_file;



# Subroutines follow

sub output_filespec {
    my ($filespec, $filename) = @_;
    local $/ = \65536;
    open (my $fh, $filespec)
	or die("$filename: $!");
    while (<$fh>) {
	print $output_fh $_;
    }
    close($fh) 
	or die("$filename: $!");
}

sub dump_to_file {
    my ($text, $filename) = @_;
    open (my $fh, ">$filename")
	or die("$filename: $!");
    print $fh $text;
    close($fh)
	or die("$filename: $!");
}


sub generate_bibtex {
    my ($text) = @_;
    my $bib;
    my %citelabels = ();
    while( $text =~ /(cite\:\d+)[,\}]/gi ) {
	$citelabels{$1} = 1;
    }
    foreach my $clabel (keys(%citelabels)) {
	$rules->{"CITE_LABEL_GIVEN"} = [ $clabel ];
	scigen::compute_re($rules, \$rules_RE); # seems inefficient
	$bib .= scigen::generate 
	    ($rules, "BIBTEX_ENTRY", $rules_RE, $debug, 'bibtex');
	$bib .= "\n";
    }
    return $bib;
}

sub pdflatex {
    my ($base) = @_;
    system("pdflatex -halt-on-error $base " . '1>&2')
	and die("pdflatex failed");
}

sub bibtex {
    my ($base) = @_;
    system("bibtex $base " . '1>&2')
	and die("bibtex failed");
}

sub makeindex {
    my ($base) = @_;
    system("makeindex $base.idx " . '1>&2')
	and die("makeindex failed");
}

sub do_output {
    my ($text) = @_;
    if ($mode eq 'raw') {
	print $output_fh $text;
	return;
    }
    setup_dir();
    my $basename = "mathgen-$seed";
    dump_to_file($text, "$basename.tex");
    dump_to_file(generate_bibtex($text), $bibname);
    
    pdflatex($basename);
    bibtex($basename);
    ($product eq 'book') and makeindex($basename);
    pdflatex($basename);
    pdflatex($basename);

    # Copy final PDF to repository outputs directory with a unique name
    eval {
        my $dest_root = $orig_cwd || '.';
        my $out_dir = File::Spec->catdir($dest_root, 'outputs');
        if (!-d $out_dir) {
            make_path($out_dir);
        }
        my $timestamp = time();
        my $unique_name = sprintf("%s-%d-%d.pdf", $basename, $timestamp, $$);
        my $src_pdf = File::Spec->catfile($dir, "$basename.pdf");
        my $dest_pdf = File::Spec->catfile($out_dir, $unique_name);
        # If the source file exists, copy it. Otherwise skip quietly.
        if (-f "$basename.pdf") {
            copy("$basename.pdf", $dest_pdf) or warn "Failed to copy PDF to $dest_pdf: $!";
            print STDERR "Copied PDF to $dest_pdf\n";
        }
    };

    # only used in some modes, but simpler to do it unconditionally
    dump_to_file(readme_text($product, $basename), 'README');

    # Now just dispose of the output appropriately
    
    if ($mode eq 'pdf') {
	output_filespec("<$basename.pdf", "$basename.pdf");
    } elsif ($mode eq 'zip') {
	# Useless Use Of Cat issue: we could have zip write to the 
	# output directly.  But we already opened it, and I don't feel like
	# special casing that for --mode=zip.  Also trying to pass the output
	# filename in a shell command seems dicey.
	output_filespec("zip - $basename.tex $basename.pdf $bibname README |",
			"zip");
    } elsif ($mode eq 'view') {
	system("$viewer $basename.pdf");
    } elsif ($mode eq 'dir') {
	# Nothing to do here!
    }
    if ($debug) {
	print STDERR "dir = $dir\n";
    }
    # We need to not be in the temp directory if it's going to be
    # deleted.  Ideally we would change back to the directory where we
    # were, but that is too much trouble, and we are not going to do
    # anything else there anyway.
    chdir('/');
}    


parse_options();
setup_seed();
open_output();
setup_rules();
do_output(generate_text());

exit 0;
