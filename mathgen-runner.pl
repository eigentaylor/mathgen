#!/usr/bin/perl -w

#    mathgen-runner.pl: Interactive/config-driven wrapper for mathgen
#
#    Copyright (C) 2012  Nathaniel Eldredge
#    This file is part of Mathgen.
#
#    Mathgen is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.

use strict;
use Getopt::Long;
use JSON;
use IO::Handle;
use File::Basename;

my $script_dir = dirname($0);

# Default configuration
my %config = (
    authors  => [],
    title    => undef,
    topics   => [],
    product  => 'article',
    mode     => 'pdf',
    output   => undef,
    seed     => undef,
    viewer   => 'evince',
    debug    => 0,
    # Bibliography options (match mathgen.pl defaults)
    bib_include_author => 1,
    bib_famous => 'all',
);

my $config_file;
my $interactive = 0;
my $help = 0;
my $logfh;
my $log_file;

sub usage {
    print STDERR <<EOUsage;

$0 [options]

A user-friendly wrapper for mathgen.pl that supports configuration files
and interactive prompts.

Options:
    --help              Display this help message
    --config=<file>     Load configuration from JSON file
    --interactive       Prompt for missing options interactively
    
    Direct options (override config file):
    --author=<name>     Author name (can repeat)
    --title=<title>     Custom title (optional)
    --topic=<topic>     Topic to bias toward (can repeat)
                        Available: topology, algebra, analysis,
                        probability, number_theory, social_choice,
                        approval_voting
    --product=<type>    article|book|blurb (default: article)
    --mode=<mode>       pdf|zip|dir|view|raw (default: pdf)
    --output=<file>     Output filename
    --seed=<int>        Random seed for reproducibility
    --viewer=<prog>     PDF viewer for --mode=view
    --debug             Enable debugging
    --bib-include-author Include paper's author in references (default: true)
    --no-bib-include-author Exclude paper's author from references
    --bib-famous=all|topic|none
                        How to include famous mathematicians in references
                        all: Use all famous mathematicians (default)
                        topic: Only use topic-specific famous names
                        none: Don't use famous mathematicians

Examples:
    # Use a config file
    $0 --config=myconfig.json

    # Interactive mode
    $0 --interactive

    # Direct options
    $0 --author="J. Doe" --topic=topology --output=paper.pdf

    # Mix config file with overrides
    $0 --config=myconfig.json --topic=algebra --output=new.pdf

EOUsage
    exit(1);
}

sub load_config {
    my ($file) = @_;
    
    open(my $fh, '<', $file) or die "Cannot open config file '$file': $!";
    my $json_text = do { local $/; <$fh> };
    close($fh);
    
    my $loaded = decode_json($json_text);
    
    # Merge loaded config with defaults
    foreach my $key (keys %$loaded) {
        if ($key eq 'authors' || $key eq 'topics') {
            $config{$key} = $loaded->{$key} if ref($loaded->{$key}) eq 'ARRAY';
        } else {
            $config{$key} = $loaded->{$key};
        }
    }
}

sub prompt {
    my ($message, $default) = @_;
    $default //= '';
    
    if ($default ne '') {
        print "$message [$default]: ";
    } else {
        print "$message: ";
    }
    
    my $input = <STDIN>;
    chomp($input);
    
    return $input ne '' ? $input : $default;
}

sub prompt_list {
    my ($message, $default_ref) = @_;
    my @defaults = $default_ref ? @$default_ref : ();
    
    print "$message\n";
    if (@defaults) {
        print "  Current: " . join(", ", @defaults) . "\n";
    }
    print "  Enter values one per line, empty line to finish:\n";
    
    my @items;
    while (1) {
        print "  > ";
        my $input = <STDIN>;
        chomp($input);
        last if $input eq '';
        push @items, $input;
    }
    
    return @items ? \@items : $default_ref;
}

sub prompt_choice {
    my ($message, $choices, $default) = @_;
    
    print "$message\n";
    my $i = 1;
    my $default_num = 1;
    foreach my $choice (@$choices) {
        my $marker = ($choice eq $default) ? '*' : ' ';
        $default_num = $i if $choice eq $default;
        print "  $marker $i) $choice\n";
        $i++;
    }
    
    my $selection = prompt("  Enter number", $default_num);
    
    if ($selection =~ /^\d+$/ && $selection >= 1 && $selection <= @$choices) {
        return $choices->[$selection - 1];
    }
    return $default;
}

sub interactive_config {
    print "\n=== Mathgen Interactive Configuration ===\n\n";
    if (defined $logfh) {
        my $ts = scalar localtime();
        print $logfh "=== Interactive run started: $ts ===\n";
    }
    
    # Authors
    $config{authors} = prompt_list("Authors", $config{authors});
    if (!@{$config{authors}}) {
        $config{authors} = ['AUTHOR'];  # Random author
        print "  (Using random author)\n";
    }
    
    print "\n";
    
    # Custom title (optional)
    my $title_input = prompt("Custom title (optional, leave blank for random)", $config{title} // '');
    $config{title} = $title_input ne '' ? $title_input : undef;
    
    print "\n";
    
    # Topics
    my @available_topics = qw(topology algebra analysis probability number_theory social_choice approval_voting);
    print "Available topics: " . join(", ", @available_topics) . "\n";
    $config{topics} = prompt_list("Topics (optional, biases content toward these areas)", $config{topics});
    
    print "\n";
    
    # Product
    $config{product} = prompt_choice(
        "Product type:",
        ['article', 'book', 'blurb'],
        $config{product}
    );
    
    print "\n";
    
    # Mode
    my @modes = ('pdf', 'zip', 'dir', 'view');
    push @modes, 'raw' if $config{product} eq 'blurb';
    $config{mode} = prompt_choice(
        "Output mode:",
        \@modes,
        $config{mode}
    );
    
    print "\n";
    
    # Output filename (required for pdf, zip, raw modes)
    if ($config{mode} eq 'pdf' || $config{mode} eq 'zip' || $config{mode} eq 'raw') {
        my $ext = $config{mode} eq 'zip' ? 'zip' : 
                  $config{mode} eq 'raw' ? 'tex' : 'pdf';
        my $default_output = $config{output} // "mathgen-output.$ext";
        $config{output} = prompt("Output filename", $default_output);
    } elsif ($config{mode} eq 'dir') {
        $config{output} = prompt("Output directory (optional)", $config{output} // '');
    }
    
    print "\n";
    
    # Seed
    my $seed_input = prompt("Random seed (optional, for reproducibility)", $config{seed} // '');
    $config{seed} = $seed_input ne '' ? int($seed_input) : undef;
    
    print "\n";
    
    # Viewer (only for view mode)
    if ($config{mode} eq 'view') {
        $config{viewer} = prompt("PDF viewer", $config{viewer});
    }
    
    # Debug
    my $debug_input = prompt("Enable debug mode? (y/n)", $config{debug} ? 'y' : 'n');
    $config{debug} = ($debug_input =~ /^y/i) ? 1 : 0;
    
    # Bibliography: include paper author in references
    my $bib_author_default = $config{bib_include_author} ? 'y' : 'n';
    my $bib_author_input = prompt("Include paper's author in references? (y/n)", $bib_author_default);
    $config{bib_include_author} = ($bib_author_input =~ /^y/i) ? 1 : 0;

    # Bibliography: famous authors handling
    print "\n";
    $config{bib_famous} = prompt_choice(
        "How to include famous mathematicians in references:",
        ['all', 'topic', 'none'],
        $config{bib_famous}
    );

    print "\n";
}

sub build_command {
    my @cmd = ('perl', '-I.', "$script_dir/mathgen.pl");
    
    # Add authors with quotes
    foreach my $author (@{$config{authors}}) {
        push @cmd, "--author=\"$author\"";
    }
    
    # Add custom title with quotes if specified
    if (defined $config{title} && $config{title} ne '') {
        push @cmd, "--title=\"$config{title}\"";
    }
    
    # Add topics
    foreach my $topic (@{$config{topics}}) {
        push @cmd, "--topic=$topic";
    }
    
    # Add other options
    push @cmd, "--product=$config{product}";
    push @cmd, "--mode=$config{mode}";
    push @cmd, "--output=$config{output}" if defined $config{output} && $config{output} ne '';
    push @cmd, "--seed=$config{seed}" if defined $config{seed};
    push @cmd, "--viewer=$config{viewer}" if $config{mode} eq 'view';
    push @cmd, "--debug" if $config{debug};
    # Bibliography options
    if ($config{bib_include_author}) {
        push @cmd, "--bib-include-author";
    } else {
        push @cmd, "--no-bib-include-author";
    }
    push @cmd, "--bib-famous=$config{bib_famous}" if defined $config{bib_famous};
    
    return @cmd;
}

sub show_config {
    print "\n=== Configuration Summary ===\n";
    print "Authors: " . (@{$config{authors}} ? join(", ", @{$config{authors}}) : "(random)") . "\n";
    print "Title: " . ($config{title} // "(random)") . "\n";
    print "Topics: " . (@{$config{topics}} ? join(", ", @{$config{topics}}) : "(none)") . "\n";
    print "Product: $config{product}\n";
    print "Mode: $config{mode}\n";
    print "Output: " . ($config{output} // "(auto)") . "\n";
    print "Seed: " . ($config{seed} // "(random)") . "\n";
    print "Debug: " . ($config{debug} ? "yes" : "no") . "\n";
    print "Include paper author in references: " . ($config{bib_include_author} ? "yes" : "no") . "\n";
    print "Famous authors in references: " . ($config{bib_famous} // "(default: all)") . "\n";
    print "\n";
}

sub save_config {
    my ($file) = @_;
    
    my $json = JSON->new->pretty->canonical;
    my $json_text = $json->encode(\%config);
    
    open(my $fh, '>', $file) or die "Cannot write config file '$file': $!";
    print $fh $json_text;
    close($fh);
    
    print "Configuration saved to: $file\n";
}

# Parse command-line options
my @cli_authors;
my @cli_topics;

GetOptions(
    "help|?" => \$help,
    "config=s" => \$config_file,
    "interactive" => \$interactive,
    "author=s@" => \@cli_authors,
    "title=s" => \$config{title},
    "topic=s@" => \@cli_topics,
    "product=s" => \$config{product},
    "mode=s" => \$config{mode},
    "output=s" => \$config{output},
    "seed=i" => \$config{seed},
    "viewer=s" => \$config{viewer},
    "debug!" => \$config{debug},
    "bib-include-author!" => \$config{bib_include_author},
    "bib-famous=s" => \$config{bib_famous},
) or usage();

usage() if $help;

# Load config file if specified
if (defined $config_file) {
    load_config($config_file);
}

# Override with command-line options
$config{authors} = \@cli_authors if @cli_authors;
$config{topics} = \@cli_topics if @cli_topics;

# Interactive mode
if ($interactive) {
    # Prepare log file for interactive runs. Truncate/clear each run so
    # the log contains only the latest interactive session. The log is
    # written to the script directory as `mathgen-runner.log`.
    $log_file = "$script_dir/mathgen-runner.log";
    if (open(my $lfh, '>', $log_file)) {
        $logfh = $lfh;
        $logfh->autoflush(1);

        # We'll write interactive output to the log explicitly rather than
        # tying STDOUT/STDERR (tied handles break IPC::Open3 which needs
        # real filehandles with a FILENO method).
        print "Interactive log: $log_file\n";

        # Hook warnings and dies to write to both STDERR and the log file
        $SIG{__WARN__} = sub {
            my $msg = shift;
            chomp $msg;
            my $s = "[WARN] $msg\n";
            print STDERR $s;
            print $logfh $s if defined $logfh;
        };
        $SIG{__DIE__} = sub {
            my $msg = shift;
            chomp $msg;
            my $s = "[DIE] $msg\n";
            print STDERR $s;
            print $logfh $s if defined $logfh;
            # propagate the die after logging
            die $msg;
        };
    } else {
        warn "Could not open log file '$log_file' for writing: $!\n";
    }

    interactive_config();
    show_config();
    
    my $proceed = prompt("Proceed with generation? (y/n/s=save config)", 'y');
    if ($proceed =~ /^s/i) {
        my $save_file = prompt("Save config to file", "mathgen.conf");
        save_config($save_file);
        if (defined $logfh) {
            print $logfh "Configuration saved to: $save_file\n";
        }
        $proceed = prompt("Proceed with generation? (y/n)", 'y');
    }
    
    exit(0) unless $proceed =~ /^y/i;
}

# Validate required options
if (!$interactive) {
    if (($config{mode} eq 'pdf' || $config{mode} eq 'zip' || $config{mode} eq 'raw') 
        && !defined $config{output}) {
        print STDERR "Error: --output is required for mode '$config{mode}'\n";
        print STDERR "Use --interactive for guided setup, or specify --output=<file>\n";
        exit(1);
    }
}

# Set default author if none specified
if (!@{$config{authors}}) {
    $config{authors} = ['AUTHOR'];
}

# Build and run the command
my @cmd = build_command();

if ($config{debug}) {
    print "Running: " . join(" ", @cmd) . "\n";
}

# Change to script directory for proper module loading
chdir($script_dir) or die "Cannot change to $script_dir: $!";

if (defined $logfh) {
    # Interactive mode: log the command and run it directly with system()
    # This allows PDF generation tools (pdflatex, bibtex, etc.) to run
    # normally without hanging on terminal interactions
    my $cmd_str = join(" ", @cmd);
    print "Running command: $cmd_str\n";
    print $logfh "Running command: $cmd_str\n";
    
    my $result = system(@cmd);
    my $exitcode = $result >> 8;
    
    my $exit_msg = "Command exited with code: $exitcode (raw: $result)\n";
    print $exit_msg;
    print $logfh $exit_msg;
    
    my $ts = scalar localtime();
    my $end_msg = "=== Interactive run ended: $ts ===\n";
    print $end_msg;
    print $logfh $end_msg;
    
    close $logfh;
    exit($exitcode);
} else {
    # Non-interactive: run with system()
    my $result = system(@cmd);
    exit($result >> 8);
}
