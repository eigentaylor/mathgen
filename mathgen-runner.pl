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
use IPC::Open3;
use Symbol qw(gensym);
use IO::Select;
use File::Basename;

# Simple tee package to duplicate prints to original handle and a log handle.
package Tee;
sub TIEHANDLE {
    my ($class, $fh_orig, $fh_log) = @_;
    return bless { orig => $fh_orig, log => $fh_log }, $class;
}
sub PRINT {
    my $self = shift;
    print {$self->{orig}} @_;
    print {$self->{log}} @_;
}
sub PRINTF {
    my $self = shift;
    my $fmt = shift;
    my $s = sprintf($fmt, @_);
    print {$self->{orig}} $s;
    print {$self->{log}} $s;
}
sub CLOSE {
    # no-op
}
package main;

my $script_dir = dirname($0);

# Default configuration
my %config = (
    authors  => [],
    topics   => [],
    product  => 'article',
    mode     => 'pdf',
    output   => undef,
    seed     => undef,
    viewer   => 'evince',
    debug    => 0,
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
    
    print "\n";
}

sub build_command {
    my @cmd = ('perl', '-I.', "$script_dir/mathgen.pl");
    
    # Add authors
    foreach my $author (@{$config{authors}}) {
        push @cmd, "--author=$author";
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
    
    return @cmd;
}

sub show_config {
    print "\n=== Configuration Summary ===\n";
    print "Authors: " . (@{$config{authors}} ? join(", ", @{$config{authors}}) : "(random)") . "\n";
    print "Topics: " . (@{$config{topics}} ? join(", ", @{$config{topics}}) : "(none)") . "\n";
    print "Product: $config{product}\n";
    print "Mode: $config{mode}\n";
    print "Output: " . ($config{output} // "(auto)") . "\n";
    print "Seed: " . ($config{seed} // "(random)") . "\n";
    print "Debug: " . ($config{debug} ? "yes" : "no") . "\n";
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
    "topic=s@" => \@cli_topics,
    "product=s" => \$config{product},
    "mode=s" => \$config{mode},
    "output=s" => \$config{output},
    "seed=i" => \$config{seed},
    "viewer=s" => \$config{viewer},
    "debug!" => \$config{debug},
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

        # Duplicate all subsequent STDOUT/STDERR to the log as well
        open my $orig_out, '>&', \\*STDOUT or warn "Could not dup STDOUT: $!\n";
        open my $orig_err, '>&', \\*STDERR or warn "Could not dup STDERR: $!\n";
        tie *STDOUT, 'Tee', $orig_out, $logfh;
        tie *STDERR, 'Tee', $orig_err, $logfh;

        print "Interactive log: $log_file\n";

        # Hook warnings and dies to STDERR so they are captured by the tee
        $SIG{__WARN__} = sub {
            my $msg = shift;
            chomp $msg;
            warn "[WARN] $msg\n";
        };
        $SIG{__DIE__} = sub {
            my $msg = shift;
            chomp $msg;
            warn "[DIE] $msg\n";
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
        print "Running command: " . join(" ", @cmd) . "\n";

        # Run the child process and capture both stdout and stderr so the
        # log contains everything the child prints. Forward the child's
        # output to STDOUT (which is tied to also write to the log).
        my $errfh = gensym;
        my $pid = open3(undef, my $child_out, $errfh, @cmd);

        my $sel = IO::Select->new();
        $sel->add($child_out);
        $sel->add($errfh);

        while (my @ready = $sel->can_read) {
            foreach my $fh (@ready) {
                my $line = <$fh>;
                if (!defined $line) {
                    $sel->remove($fh);
                    next;
                }
                # Print only to STDOUT; the tie will duplicate to the log
                print $line;
            }
        }

        # Wait for child to exit
        waitpid($pid, 0);
        my $result = $?;
        my $exitcode = $result >> 8;
        print "Command exited with code: $exitcode (raw: $result)\n";
        my $ts = scalar localtime();
        print "=== Interactive run ended: $ts ===\n";

        # Untie and restore original handles
        untie *STDOUT;
        untie *STDERR;
        close $logfh;
        exit($exitcode);
    } else {
        # Non-interactive: fall back to system()
        my $result = system(@cmd);
        exit($result >> 8);
    }
