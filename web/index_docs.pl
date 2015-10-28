#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;
use utf8;

use FindBin;

BEGIN {
    chdir "$FindBin::RealBin/..";
    do "web/base.pl" or die $!;
}

use Proc::PID::File;
die "$0 already running\n" if Proc::PID::File->running( dir => '.run' );

our ( $Guide_Prefix, $Docs_Index, $es );

use YAML qw(LoadFile);
use Path::Class qw(dir file);
use Encode qw(decode_utf8);
use ES::Util qw(run $Opts sha_for);
use ES::DocsParser();
use Getopt::Long;

our $Conf = LoadFile('conf.yaml');

GetOptions( $Opts, 'force' );

if ( !$Opts->{force} and sha_for("HEAD") eq sha_for('_index') ) {
    say "Up to date";
    exit;
}

say "Indexing docs";
main();
run qw(git branch -f _index HEAD);
exec('web/update_tags.pl');

#===================================
sub main {
#===================================
    my $dir = $Conf->{paths}{build}
        or die "Missing <paths.build> from config";
    $dir = dir($dir);

    my $index = create_index($Docs_Index);

    my @docs;
    eval {
        for my $book ( books( '', @{ $Conf->{contents} } ) ) {
            say "Indexing book: $book->{title}";
            my $b = $es->bulk_helper(
                index     => $index,
                type      => 'doc',
                max_count => 100
            );

            my @docs = index_docs( $b, $dir, $book->{prefix}, $book->{tags},
                $book->{single} );

            my $result = $b->flush;

            die join "\n", "Error indexing $book->{title}:",
                map { $_->{error} } @{ $result->{errors} }
                if $result->{errors};
        }

        $es->indices->optimize( index => $index, max_num_segments => 1 );
        1;
    } or do {
        my $error = $@;
        $es->indices->delete( index => $index );
        die $error;
    };
    switch_alias( $Docs_Index, $index );
}

#===================================
sub index_docs {
#===================================
    my ( $bulk, $dir, $prefix, $tags, $single ) = @_;

    $tags =~ s/[- _]+/-/g;

    my $length_dir = length($dir);
    my $book_dir   = $dir->subdir($prefix);
    my @versions   = grep { $_->is_dir } $book_dir->children();

    for my $version_dir (@versions) {
        my @files;
        my $toc = $version_dir->file('toc.html');
        if ( -e $toc ) {
            my $content = $toc->slurp( iomode => "<:encoding(UTF-8)" );
            @files = ( $content =~ /href="([^"]+)"/g );
        }
        else {
            @files = 'index.html';
        }

        my $version = $version_dir->basename;
        my $is_current = $version eq 'current' ? \1 : \0;

        my $section = @versions > 2    # current and master
            ? 'Docs/' . $tags . '/' . $version
            : 'Docs/' . $tags;

        my ( $product, $book_title ) = split '/', $tags;

        for (@files) {
            my $file = $version_dir->file($_);
            my $url = $Guide_Prefix . substr( $file, $length_dir );

            for my $page ( _load_file( $file, $single ) ) {

                # single-page books don't have their titles detected
                my $title = $page->{title} || $book_title;

                $bulk->index(
                    {   _id     => $url . $page->{id},
                        _source => {
                            title          => $title,
                            content        => $page->{text},
                            url            => $url . $page->{id},
                            tags           => [ $product, $section ],
                            section        => $section,
                            is_current     => $is_current,
                            is_sub_section => $page->{main} ? \0 : \1
                        }
                    }
                );
            }
        }
    }
    return;
}

#===================================
sub _load_file {
#===================================
    my ( $file, $single ) = @_;
    my $content = $file->slurp( iomode => '<:encoding(UTF-8)' );
    my $parser = ES::DocsParser->new;
    $parser->parse($content);
    my $sections = $parser->output;

    my $page_title = $single ? '' : $sections->[0]{title};
    my $page_text = $sections->[0]{text};
    shift @$sections;

    for my $section (@$sections) {
        $page_text .= "\n\n" . $section->{title} . "\n\n" . $section->{text};
        $section->{title} .= " » $page_title" unless $single;
    }
    return ( { title => $page_title, text => $page_text, id => '', main => 1 },
        @$sections );
}

#===================================
sub books {
#===================================
    my @books;
    my $base_dir = shift();
    while ( my $next = shift @_ ) {
        if ( $next->{sections} ) {
            if ( $next->{base_dir} ) {
                $base_dir .= '/' . $next->{base_dir};
            }
            push @books, books( $base_dir, @{ $next->{sections} } );
        }
        else {
            my %details = %$next;
            if ($base_dir) {
                $details{prefix} = $base_dir . "/" . $details{prefix};
            }
            push @books, \%details;
        }
    }
    return @books;
}

#===================================
sub usage {
#===================================
    say <<USAGE;

    Index all generated HTML docs in the build directory

        $0 [opts]

        Opts:
          --force           Reindex the docs even if already up to date

USAGE
}
