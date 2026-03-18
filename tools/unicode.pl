#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use File::Basename;
use Pod::Usage;
use JSON;
use Encode;
use utf8;

=head1 SYNOPSIS

 tools/unicode.pl <command> [options]

 Commands
     import_ucd                Import Unicode Character Database
     decompose                 Generate ASCII equivalents by decomposing characters
     import_confusables        Import confusables from unicode.org
     list_all                  List all Unicode characters
     list_zw                   List all zero-width characters
     list_homoglyphs [<char>]  List homoglyphs of <char> or all characters if <char> is not specified
     find_missing              Find missing characters
     list_ascii                List ASCII characters
     generate_map              Generate character map data for use in ASCII.pm
     test_map                  Test character map
     replace_tags              Generate replace_tag code suitable for use in SpamAssassin
     convert <string>          Convert a string of unicode characters to ASCII
     explain <string>          Decode a string of unicode characters and output detailed information

=head1 AUTHORS

Kent Oyer <kent@mxguardian.net>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2023 MXGuardian LLC

This is free software; you can redistribute it and/or modify it under
the terms of the Apache License 2.0. See the LICENSE file included
with this distribution for more information.

This plugin is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.


=cut

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

# Read database config from .env file
my %env;
my $env_file = dirname(__FILE__) . '/.env';
if (open my $efh, '<', $env_file) {
    while (<$efh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;
        if (/^(\w+)\s*=\s*(.*)$/) {
            $env{$1} = $2;
        }
    }
    close $efh;
} else {
    die "Cannot open $env_file: $!\n";
}

my $db_host = $env{DATABASE_HOST}     || 'localhost';
my $db_user = $env{DATABASE_USER}     || 'root';
my $db_pass = $env{DATABASE_PASSWORD} || '';
my $db = DBI->connect(
    "DBI:mysql:database=unicode_db;host=$db_host",
    $db_user, $db_pass,
    { RaiseError => 1, mysql_enable_utf8mb4 => 1 }
) or die "Cannot connect to database: $DBI::errstr\n";

# Convenience wrappers
sub db_fetch    { my ($sql, @bind) = @_; my $sth = $db->prepare($sql); $sth->execute(@bind); return $sth->fetchrow_hashref; }
sub db_fetchAll { my ($sql, @bind) = @_; my $sth = $db->prepare($sql); $sth->execute(@bind); return $sth->fetchall_arrayref({}); }

my $dispatch = {
    'create_schema'      => \&create_schema,
    'import_ucd'         => \&import_ucd,
    'decompose'          => \&decompose,
    'import_confusables' => \&import_confusables,
    'list_homoglyphs'    => \&list_homoglyphs,
    'list_zw'            => \&list_zw,
    'list_all'           => \&list_all,
    'find_missing'       => \&find_missing,
    'list_ascii'         => \&list_ascii,
    'generate_map'       => \&generate_map,
    'test_map'           => \&test_map,
    'replace_tags'       => \&replace_tags,
    'convert'            => \&convert,
    'explain'            => \&explain,
};

my $cmd = shift @ARGV;
pod2usage(1) unless defined($cmd);
die "Unknown command '$cmd'" unless $dispatch->{$cmd};
$dispatch->{$cmd}->();

#
# Create DB tables
#
sub create_schema {

    my @sql = split /;\s*/, <<SQL;
CREATE TABLE `chars` (
                        `hcode` char(5) NOT NULL,
                        `description` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
                        `ascii` char(6) CHARACTER SET latin1 DEFAULT NULL,
                        `block` varchar(255) DEFAULT NULL,
                        `script` char(4) DEFAULT NULL,
                        `category` char(2) DEFAULT NULL,
                        `bidi_class` char(3) DEFAULT NULL,
                        `combining_class` int(4) DEFAULT NULL,
                        `is_upper` tinyint(1) NOT NULL DEFAULT '0',
                        `is_lower` tinyint(1) NOT NULL DEFAULT '0',
                        `is_emoji` tinyint(1) NOT NULL DEFAULT '0',
                        `is_whitespace` tinyint(1) NOT NULL DEFAULT '0',
                        `is_printable` tinyint(1) NOT NULL DEFAULT '1',
                        `is_zero_width` tinyint(1) NOT NULL DEFAULT '0',
                        `decomposition` varchar(255) DEFAULT NULL,
                        `uppercase` varchar(255) DEFAULT NULL,
                        `lowercase` varchar(255) DEFAULT NULL,
                        `dcode` int(11) unsigned DEFAULT NULL,
                        `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                        PRIMARY KEY (`hcode`),
                        KEY `sort` (`dcode`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TRIGGER `before_ins` BEFORE INSERT ON `chars` FOR EACH ROW SET NEW.dcode = CONV(NEW.hcode,16,10);

CREATE TABLE `special` (
                           `first_dcode` int(11) unsigned NOT NULL,
                           `last_dcode` int(11) unsigned NOT NULL,
                           `description` varchar(255) DEFAULT NULL,
                           PRIMARY KEY (`first_dcode`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SQL

    for (@sql) {
        chomp;
        $db->do($_);
    }

}
#
# Import Unicode Character Database
#
# http://www.unicode.org/Public/UCD/latest/ucdxml/ucd.nounihan.grouped.zip
#
sub import_ucd {

    use LWP::UserAgent;
    use XML::Parser;
    use Archive::Zip;

    my $ins_char = $db->prepare("INSERT IGNORE INTO `chars`
        (`hcode`,description,block,script,category,bidi_class,combining_class,
        is_upper,is_lower,is_emoji,is_whitespace,is_printable,
        decomposition,uppercase,lowercase)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");

    my $ins_special = $db->prepare("INSERT IGNORE INTO `special`
        (first_dcode,last_dcode,description) VALUES (?,?,?)");

    my $group;
    my $xml = XML::Parser->new(Handlers => {
        Start => sub {
            my ($expat,$tag,%attr) = @_;
            if ( $tag eq 'char' ) {
                my $first_dcode;
                my $last_dcode;
                if ( defined($attr{cp}) ) {
                    $first_dcode = $last_dcode = hex($attr{cp});
                } else {
                    $first_dcode = hex($attr{'first-cp'});
                    $last_dcode = hex($attr{'last-cp'});
                }
                my $name = $attr{na} || $group->{na} || $attr{na1} || $group->{na1} || '';
                my $block = $attr{blk} || $group->{blk};
                my $script = $attr{sc} || $group->{sc};
                my $cat = $attr{gc} || $group->{gc};
                my $upper = $attr{Upper} || $group->{Upper} || 'N';
                my $lower = $attr{Lower} || $group->{Lower} || 'N';
                my $emoji = $attr{Emoji} || $group->{Emoji} || 'N';
                my $whitespace = $attr{WSpace} || $group->{WSpace} || 'N';
                my $uc = $attr{uc} || $group->{uc};
                my $lc = $attr{lc} || $group->{lc};
                my $decomp = $attr{dm} || $group->{dm};
                my $bc = $attr{bc} || $group->{bc};
                my $cc = $attr{ccc} || $group->{ccc};
                my $printable = 1;
                $printable = 0 if $cat =~ /^Cc$/;
                $printable = 0 if $bc =~ /^(BN|LR|RL|PD|FS)/;
                for (my $dcode=$first_dcode;$dcode<=$last_dcode;$dcode++) {

                    my $hcode = sprintf("%04X",$dcode);
                    my $char = chr($dcode);
                    my $desc = $name;
                    $desc =~ s/#/$hcode/;
                    $desc = $char . ' ' . $desc if $printable==1;

                    $ins_char->execute(
                        $hcode,
                        $desc,
                        $block,
                        $script,
                        $cat,
                        $bc,
                        $cc,
                        $upper eq 'Y'?1:0,
                        $lower eq 'Y'?1:0,
                        $emoji eq 'Y'?1:0,
                        $whitespace eq 'Y'?1:0,
                        $printable,
                        $decomp eq '#' ? undef: $decomp,
                        $uc eq '#' ? undef: $uc,
                        $lc eq '#' ? undef: $lc,
                    );
                } # end for

            } elsif ( $tag eq 'group' ) {
                $group = \%attr;

            } elsif ( $tag eq 'reserved' ) {
                my $first_dcode;
                my $last_dcode;
                if ( defined($attr{cp}) ) {
                    $first_dcode = $last_dcode = hex($attr{cp});
                } else {
                    $first_dcode = hex($attr{'first-cp'});
                    $last_dcode = hex($attr{'last-cp'});
                }
                $ins_special->execute($first_dcode,$last_dcode,'Reserved');

            } elsif ( $tag eq 'surrogate' ) {
                my $first_dcode;
                my $last_dcode;
                if ( defined($attr{cp}) ) {
                    $first_dcode = $last_dcode = hex($attr{cp});
                } else {
                    $first_dcode = hex($attr{'first-cp'});
                    $last_dcode = hex($attr{'last-cp'});
                }
                my $desc = $attr{blk} || 'Surrogate';
                $ins_special->execute($first_dcode,$last_dcode,$desc);

            } elsif ( $tag eq 'noncharacter' ) {
                my $first_dcode;
                my $last_dcode;
                if ( defined($attr{cp}) ) {
                    $first_dcode = $last_dcode = hex($attr{cp});
                } else {
                    $first_dcode = hex($attr{'first-cp'});
                    $last_dcode = hex($attr{'last-cp'});
                }
                $ins_special->execute($first_dcode,$last_dcode,'Non-Character');

            } # end if
        } # end start
    });

    my $xml_file = "/tmp/ucd.nounihan.grouped.xml";
    if ( ! -f $xml_file ) {
        my $zip_file = "/tmp/ucd.nounihan.grouped.zip";
        my $url = 'http://www.unicode.org/Public/UCD/latest/ucdxml/ucd.nounihan.grouped.zip';
        print "Downloading $url\n";
        my $ua = LWP::UserAgent->new();
        my $response = $ua->get($url, ':content_file' => $zip_file);
        die $response->status_line unless $response->is_success;

        print "Extracting to $xml_file\n";
        my $zip = Archive::Zip->new();
        $zip->read($zip_file);
        $zip->extractMember('ucd.nounihan.grouped.xml', $xml_file);
    }

    print "Importing $xml_file...This will take a Micro\$oft minute.\n";
    $xml->parsefile($xml_file);

}

#
# Import Confusables
#
# https://www.unicode.org/Public/security/latest/confusables.txt
#
sub import_confusables {

    use LWP::UserAgent;

    our $upd_char = $db->prepare("UPDATE `chars` SET ascii = ? WHERE hcode = ?");

    sub _save_confusables {
        my ($confusables) = @_;

        return unless defined($confusables) && scalar(@$confusables)>0;

        my @ascii = grep { $_ =~ /^[[:ascii:]]$/ } @$confusables;
        if ( scalar(@ascii) == 0 ) {
            # print "No ASCII equivalent for ".join(' ',@$confusables)."\n";
            return;
        }
        my $ascii = $ascii[0];
        if ( scalar(@ascii) > 1 ) {
            print STDERR "Warning: Multiple ASCII equivalents for ".join(' ',@$confusables)."\n";
            # insert placeholder so we can find these later
            $ascii = '_?_';
        }

        # print "Saving $ascii: ".join(' ',@$confusables)."\n";

        foreach my $confusable (@$confusables) {
            next if $confusable eq $ascii;
            next if length($confusable) != 1;
            my $hcode = sprintf("%04X",ord($confusable));
            # print "$hcode: $confusable -> $ascii\n";
            $upd_char->execute($ascii,$hcode);
        }
    }

    my $filename = '/tmp/confusables.txt';
    if ( ! -f $filename ) {
        my $url = 'https://www.unicode.org/Public/security/latest/confusables.txt';
        print "Downloading $url\n";
        my $ua = LWP::UserAgent->new;
        my $response = $ua->get($url, ':content_file' => $filename);
        die $response->status_line unless $response->is_success;
    }
    open(my $fh, '<:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";

    my @confusables;
    foreach my $line (<$fh>) {

        # remove comments and blank lines
        $line =~ s/#.*$//;
        next if $line =~ /^\s*$/;

        # split on tabs
        my @fields = split /\t/,$line;
        # print join('|',@fields), "\n";

        # get code points and convert to characters
        my $str = $fields[2];
        next unless defined($str);
        $str =~ s/([0-9a-f]{4,6})\s*/chr(hex($1))/gei;

        if ( !$fields[0] ) {
            _save_confusables(\@confusables);
            @confusables = ();
        }
        push @confusables, $str;
    }
    _save_confusables(\@confusables);
}

sub decompose {
    our $sel_chars = $db->prepare("SELECT * FROM `chars` WHERE ascii IS NULL AND decomposition IS NOT NULL");
    our $upd_chars = $db->prepare("UPDATE `chars` SET ascii = ? WHERE hcode = ? AND ascii IS NULL");

    print "Decomposing characters...\n";

    $sel_chars->execute();
    while (my $char = $sel_chars->fetchrow_hashref()) {
        my $ascii = _decompose($char->{decomposition});
        $ascii =~ s/[^[:ascii:]]//g;
        next unless length($ascii) && $ascii ne '()';
        # print chr(hex($char->{hcode}))." $ascii\n";
        $upd_chars->execute($ascii, $char->{hcode});
    }

    sub _decompose {
        my ($chars) = @_;
        my $base = '';
        foreach my $char (split /\s+/, $chars) {
            my $data = db_fetch("SELECT decomposition,ascii FROM `chars` WHERE hcode = ?", $char);
            if ( defined($data->{decomposition}) ) {
                $base .= _decompose($data->{decomposition});
            } elsif ( defined($data->{ascii}) ) {
                $base .= $data->{ascii};
            } else {
                $base .= chr(hex($char));
            }
        }
        return $base;
    }

}

#
# Generate replace_tags
#
sub replace_tags {

    my %defaults = (
        'A' => [ qw(@ 4) ],
        'B' => [ qw(8 6) ],
        'E' => [ qw(3) ],
        'I' => [ qw(l 1) ],
        'L' => [ qw(I 1) ],
        'O' => [ qw(0) ],
        'S' => [ qw(5 $) ],
    );

    my $chars = db_fetchAll("SELECT ascii,hcode FROM `chars` WHERE ascii IS NOT NULL ORDER BY ascii");
    my @patterns;
    my $last_ascii = '';
    foreach my $char (@$chars) {
        if ( uc($char->{ascii}) ne $last_ascii ) {
            if ( $last_ascii =~ /^[A-Z]$/ ) {
                my $re = generate_regex(@patterns);
                print "replace_tag    ${last_ascii}1    $re\n";
            }
            $last_ascii = uc($char->{ascii});
            @patterns = ( lc($char->{ascii}), uc($char->{ascii}), hex_to_utf8re($char->{hcode}) );
            push @patterns, @{$defaults{$last_ascii}} if (defined($defaults{$last_ascii}));
        } else {
            push(@patterns,hex_to_utf8re($char->{hcode}));
        }
    }

}

#
# List of homoglyphs
#
sub list_all_homoglyphs {
    my $chars = db_fetchAll("SELECT ascii,hcode FROM `chars` WHERE ascii IS NOT NULL ORDER BY ascii");
    my $str;
    my $last_ascii = '';
    foreach my $char (@$chars) {
        if ( uc($char->{ascii}) ne $last_ascii ) {
            printf "%-6s: %s\n",${last_ascii},$str if defined($str);
            $last_ascii = uc($char->{ascii});
            $str = chr(hex($char->{hcode}));
        } else {
            $str .= ' ' . chr(hex($char->{hcode}));
        }
    }

}

#
# List homoglyphs of a given character
#
sub list_homoglyphs {
    my ($ascii) = @ARGV;
    if ( !defined($ascii) ) {
        return list_all_homoglyphs();
    }
    my $chars = db_fetchAll("SELECT * FROM `chars` WHERE ascii = ? ORDER BY dcode",$ascii);
    foreach my $char (@$chars) {
        my $hcode = $char->{hcode};
        # as a unicode string
        my $str = chr(hex($hcode));
        # utf8 in bytes
        my $utf8bytes = encode("utf8", $str);
        # utf8bytes in hex
        my $utf8hex = uc(unpack("H*", $utf8bytes));
        $utf8hex =~ s/(..)/\\x$1/g;

        my $desc = $char->{description}||'';
        $desc = decode("utf8",$desc);
        printf "U+%-5s %-17s %s\n", $hcode, $utf8hex, $desc;
    }
}



#
# list all Unicode characters
#
sub list_all {
    my $chars = db_fetchAll("SELECT * FROM `chars` ORDER BY dcode");
    foreach my $char (@$chars) {
        my $hcode = $char->{hcode};
        # as a unicode string
        my $str = chr(hex($hcode));
        # utf8 in bytes
        my $utf8bytes = encode("utf8", $str);
        # utf8bytes in hex
        my $utf8hex = uc(unpack("H*", $utf8bytes));
        $utf8hex =~ s/(..)/\\x$1/g;

        my $desc = $char->{description}||'';
        $desc = decode("utf8",$desc);
        printf "U+%s %-15s %s\n", $hcode, $utf8hex, $desc;
    }
}

#
# List all zero-width characters
#
sub list_zw {
    my $chars = db_fetchAll("SELECT * FROM `chars` WHERE is_zero_width = 1 ORDER BY dcode");
    foreach my $char (@$chars) {
        my $hcode = $char->{hcode};
        # as a unicode string
        my $str = chr(hex($hcode));
        # utf8 in bytes
        my $utf8bytes = encode("utf8", $str);
        # utf8bytes in hex
        my $utf8hex = uc(unpack("H*", $utf8bytes));
        $utf8hex =~ s/(..)/\\x$1/g;

        my $desc = $char->{description}||'';
        printf "U+%s %-15s %s\n", $hcode, $utf8hex, $desc;
    }
}

#
# List all unicode characters with ascii equivalents
#
sub list_ascii {
    my $chars = db_fetchAll("SELECT * FROM `chars` WHERE ascii IS NOT NULL ORDER BY dcode");
    foreach my $char (@$chars) {
        my $hcode = $char->{hcode};
        my $str = chr(hex($hcode));
        printf "U+%s %s %s\n", $hcode, $str, $char->{ascii};
    }
}

#
# List all unicode characters
#
sub generate_map {

    my $filename = 'lib/Text/ASCII/Convert.pm';
    open my $fh, '+<', $filename or die "Cannot open $filename: $!";

    # Find the start of the __DATA__ section
    seek $fh, 0, 0;
    while (<$fh>) {
        last if /^__DATA__\r?\n/;
    }
    if (eof $fh) {
        # No __DATA__ section found, append one
        print $fh "__DATA__\n";
    } else {
        # Truncate the file at the start of the __DATA__ section
        truncate $fh, tell($fh);
    }

    my $chars = db_fetchAll("SELECT * FROM `chars` WHERE ascii IS NOT NULL ORDER BY dcode");
    foreach my $char (@$chars) {
        my $hcode = $char->{hcode};
        my $ascii = $char->{ascii};
        $ascii = ' ' if ($ascii =~ /^\s*$/);  #
        $ascii = join('+', map { sprintf("%02X", ord($_)) } split //, $ascii);
        printf $fh "%s %s\n", $hcode, $ascii;
    }
    close $fh;
    print "Updated $filename with new char map\n";
}

sub convert {

    my $body = @_ ? join(' ',@_) : join(' ',@ARGV);
    $body = decode("utf8",$body,Encode::FB_WARN) unless utf8::is_utf8($body);

    use lib 'lib';
    use Text::ASCII::Convert;

    print convert_to_ascii($body), "\n";

}

#
# Find missing characters
#
sub find_missing {

    my $special = db_fetchAll("SELECT * FROM special ORDER BY first_dcode");
    my $chars = db_fetchAll("SELECT dcode FROM `chars` ORDER BY dcode");

    my $last_dcode = -1;
    my $c = shift(@$chars);
    my $s = shift(@$special);
    while ( defined($c) ) {
        my $dcode;
        if ( !defined($s) || $c->{dcode} < $s->{first_dcode} ) {
            $dcode = $c->{dcode};
        } else {
            $dcode = $s->{first_dcode};
        }
        if ($dcode > $last_dcode + 1) {
            my $count = $dcode - $last_dcode - 1;
            printf "Missing: U+%04X - U+%04X (%d)\n", $last_dcode + 1, $dcode - 1, $count;
        } elsif ( $dcode < $last_dcode + 1) {
            my $count = ($last_dcode + 1) - $dcode;
            printf "Overlap: U+%04X - U+%04X (%d)\n", $dcode, $last_dcode, $count;
        }
        if ( !defined($s) || $c->{dcode} < $s->{first_dcode} ) {
            $last_dcode = $dcode;
            $c = shift(@$chars);
        } else {
            $last_dcode = $s->{last_dcode};
            $s = shift(@$special);
        }
    }

}

sub explain {
    my $sel_char = $db->prepare("SELECT * FROM `chars` WHERE dcode = ?");
    foreach my $str (@ARGV) {
        if ( $str =~ /^U\+([0-9a-f]{4,5})$/i ) {
            $str = chr(hex($1));
        } else {
            $str =~ s/\\x\{?([0-9a-f]{2})\}?/chr(hex($1))/gei;
            $str = decode("utf8",$str,Encode::FB_WARN);
        }
        foreach my $char (split //,$str) {
            my $dcode = ord($char);
            $sel_char->execute($dcode);
            my $row = $sel_char->fetchrow_hashref;
            my $hcode = $row->{hcode};
            my $desc = $row->{description};
            if ( $row->{is_printable} ) {
                # fix description to include character
                $desc = chr($dcode) . ' ' . substr($desc,2);
            }
            # print ASCII in green, others in red
            my $color = $dcode < 128 ? '0' : $dcode < 256 ? '33': '31';
            printf "\e[%sm%-50s U+%04X %s\e[0m\n", $color, $desc, $dcode, hex_to_utf8re($hcode);
        }
    }
}

sub hex_to_string {
    my $hex = shift;
    my $chars = '';
    foreach my $cp (split /\s+/,$hex) {
        $chars .= chr(hex($cp));
    }
    return $chars;
}

sub hex_to_utf8re {
    my $hex = shift;
    $hex =~ s/([0-9a-f]{4,6})\s*/chr(hex($1))/gei;
    my $bytes = encode('utf8',$hex);
    # convert bytes to re
    my $re = join('',map { sprintf('\x%02X',ord($_)) } split //,$bytes);
    return $re;
}

sub unicode_to_utf8re {
    my $unicode = shift;
    my $bytes = encode('utf8', $unicode);
    # convert bytes to re
    my $re = join('', map {sprintf('\x%02X', ord($_))} split //, $bytes);
    return $re;
}

sub generate_regex {
    my @strings = @_;

    return '' unless @strings;

    my %hash;
    foreach my $string (@strings) {
        $string =~ s/\\x([0-9a-f]{2})/chr(hex($1))/gei;
        my $h = \%hash;
        foreach my $char (split //, $string) {
            $h->{$char} = {} unless exists $h->{$char};
            $h = $h->{$char};
        }
    }
    my $regex = parse_tree(\%hash);
    $regex =~ s/([^ -~])/sprintf("\\x%X", ord($1))/ge;
    $regex = "(?:$regex)" unless $regex =~ /^\(/;
    $regex =~ s/^\(\?:/\(\?-i:/;    # disable case-insensitive matching
    return $regex;

    sub parse_tree {
        my ($h) = @_;

        my @patterns;
        my $max_len = 0;
        foreach my $key (sort keys %$h) {
            my $str;
            if (keys %{$h->{$key}}) {
                $str =  $key . parse_tree($h->{$key});
            } else {
                $str = $key;
            }
            push @patterns, $str;
            $max_len = length($str) if length($str) > $max_len;
        }

        return '' unless @patterns;
        return $patterns[0] if @patterns == 1;
        return '(?:' . join('|', @patterns) . ')' if $max_len > 1;

        # If all patterns are single characters, we can use a character class
        # and we can look for ranges
        my @ranges;
        my $prev = ord($patterns[0]);
        my $start = $prev;
        for (my $i = 1; $i < @patterns; $i++) {
            my $ord = ord($patterns[$i]);
            if ($ord == $prev + 1) {
                $prev = $ord;
            } else {
                push @ranges, $start == $prev ? chr($start)
                    : $start+1 == $prev ? chr($start) . chr($prev)
                    : chr($start) . '-' . chr($prev);
                $start = $prev = $ord;
            }
        }
        push @ranges, $start == $prev ? chr($start)
            : $start+1 == $prev ? chr($start) . chr($prev)
            : chr($start) . '-' . chr($prev);
        return '[' . join('', @ranges) . ']';
    }

}
