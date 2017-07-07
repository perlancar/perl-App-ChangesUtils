package App::ChangesUtils;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'CLI utilities related to distribution Changes file',
};

my %args_common = (
    filename => {
        summary => 'Changes file',
        schema => 'filename*',
        cmdline_aliases => {f=>{}},
        description => <<'_',

By default will search for files named `Changes`, `CHANGES`, `ChangeLog`,
`CHANGELOG` in the current directory.

_
    },
);

sub _increment_version {
    require Version::Util;
    require Text::Wrap;

    my $version = shift;

    log_trace("Incrementing version %s", $version);
    if ($version =~ /\A(\d+)\z/) {
        $version = Version::Util::add_version($version, "1");
    } elsif ($version =~ /\A(\d+\.)(\d+)\z/) {
        $version = Version::Util::add_version(
            $version, length($2) == 1 ? "0.1" :
                length($2) == 2 ? "0.01" :
                                   "0.001");
    } elsif ($version =~ /\A(\d+\.\d+\.)(\d+)/) {
        $version = Version::Util::add_version(
            $version, length($2) == 1 ? "0.0.1" :
                length($2) == 2 ? "0.0.01" :
                "0.0.001");
    } else {
        die "Don't know how to increment version format '$version' ".
            "(only recognize 123, 1.23, or 1.2.3";
    }
    log_trace("Will increment version to %s", $version);
    $version;
}

sub _set_common_args {
    my $args = shift;

    unless (defined $args->{filename}) {
        for (qw/Changes CHANGES ChangeLog CHANGELOG/) {
            if (-f $_) {
                $args->{filename} = $_;
                last;
            }
        }
        die "Can't find file that is named like a Changes file, ".
            "please specify via -f\n" unless defined $args->{filename};
    }
}

$SPEC{add_changes_entry_from_commits} = {
    v => 1.1,
    summary => 'Add a new release entry, from items from commit log messages',
    args => {
        %args_common,
        functional_changes => {
            summary => 'Whether a release has functional changes',
            schema  => 'bool*',
            default => 1,
            description => <<'_',

If set to false, will add this item to Changes:

    - No functional changes.

or, if this is a spec distribution (`.tag-spec` exists), will add this item:

    - No spec changes.

or, if this is a data distribution (`.tag-data` exists), will add this item:

    - No data changes.

_
            cmdline_aliases => {
                F => {
                    schema  => ['bool*', is=>1],
                    summary => 'Shortcut for --no-functional-changes',
                    code    => sub { $_[0]{functional_changes} = 0 },
                },
            },
        },
        num_skip_commits => {
            schema  => ['int*', min=>0],
            summary => 'Skip this number of commits first',
            cmdline_aliases => { s=>{} },
        },
        num_commits => {
            schema  => ['int*', min=>1],
            default => 1,
            cmdline_aliases => { n=>{} },
        },
    },
};
sub add_changes_entry_from_commits {
    require Proc::ChildError;

    my %args = @_;

    _set_common_args(\%args);
    my $func_changes = $args{functional_changes} // 1;

    my $version;
    my $content_dist_ini;
    my $version_from_dist_ini;

  VERSION_FROM_DIST_INI:
    {
        # try to get version from dist.ini
        last unless -f "dist.ini";
        open my($fh), "<", "dist.ini"
            or return [500, "Can't open dist.ini: $!"];
        $content_dist_ini = do { local $/; ~~<$fh> };
        if ($content_dist_ini =~ /^\s*version\s*=\s*(.+)/m) {
            $version = $1;
            log_trace("Extracted version from dist.ini: %s", $version);
            $version_from_dist_ini++;
        } else {
            log_warn("Can't extract version from dist.ini");
            last;
        }
        $version = _increment_version($version);
    }
    $version //= '{{NEXT}}';

    # get changes entry from 'git commit'
    my $n = $args{num_commits} // 1; $n+=0;
    my $s = $args{num_skip_commits} // 0; $s+=0;
    my $ct_log = readpipe("git log -n " . ($n+$s));
    $? and return [500, "Can't get commit log: ".
                       Proc::ChildError::explain_child_error()];
    my @commits = grep {/\S/} split /^commit .+?\n\n/ms, $ct_log;
    splice @commits, 0, $s if $s;

    my $is_spec_dist = (-f ".tag-spec");
    my $is_data_dist = (-f ".tag-data");
    if (!$func_changes) {
        unshift @commits,
            $is_spec_dist ? "No spec changes" :
            $is_data_dist ? "No data changes" :
            "No functional changes";
    }

    # create entry
    my $entry;
    {
        my $author;
        if (glob ".tag-proj-*") {
            chomp($author = `git config user.name`);
            die "No user.name is set in git.config" unless $author;
            $author =~ s/\s*\(.+\)//;
        } else {
            $author = $ENV{PAUSEID} // 'PAUSEID';
        }

        my $date = POSIX::strftime("%Y-%m-%d", localtime);
        my $indent = length($version) + 2; $indent = 8 if $indent < 8;
        $entry = sprintf "%-${indent}s%s (%s)\n\n",
            $version, $date, $author;
        for (@commits) {
            s/^\s+//s;
            s/\s+\z//s;
            $_ .= "." unless /\.\z/;
            $entry .= Text::Wrap::wrap(
                (" " x $indent) . "- ",
                (" " x $indent) . "  ",
                $_);
            $entry .= "\n\n";
        }
        $entry .= "\n";
    }

    # modify Changes
    open my $fh, "<", $args{filename}
        or return [500, "Can't open $args{filename}: $!"];
    my $ct_ch = do { local $/; ~~<$fh> };
    close $fh;
    open $fh, ">", $args{filename}
        or return [500, "Can't open $args{filename} (2): $!"];
    $ct_ch =~ s/^(?=\d)/$entry/m
        or return [500, "Can't insert entry to $args{filename}"];
    print $fh $ct_ch;
    close $fh or return [500, "Can't write $args{filename}: $!"];

    # modify dist.ini
    if ($version_from_dist_ini) {
        open $fh, ">", "dist.ini"
            or return [500, "Can't open dist.ini (2): $!"];
        $content_dist_ini =~ s/^(\s*version\s*=\s*)(.+)/${1}$version/m
            or return [500, "Can't replace version in dist.ini"];
        print $fh $content_dist_ini;
        close $fh or return [500, "Can't write dist.ini: $!"];
    }

    [200, "OK"];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

=head1 DESCRIPTION

This distribution includes several utilities:

#INSERT_EXECS_LIST
