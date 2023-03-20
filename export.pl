#!/usr/bin/env perl

use strict;
use warnings;

use Dotenv -load;
use DBI ();
use JSON ();
use DateTime::Format::ISO8601 ();
use DateTime ();
use HTML::FromText ();

my $coder = JSON->new->pretty->canonical;
my $strp = DateTime::Format::Strptime->new(
    'pattern'   => '%F %T',
    'time_zone' => $ENV{'B2EVO_GHOST_TIMEZONE'} // 'UTC',
);
my $iso8601 = DateTime::Format::ISO8601->new();

my $t2h = HTML::FromText->new({
    metachars  => 0,
    paras      => 1,
    blockcode  => 1,
    tables     => 1,
    bullets    => 1,
    numbers    => 1,
    urls       => 1,
    email      => 1,
    bold       => 1,
    underline  => 1,
});

my $dbh = DBI->connect(
    $ENV{'B2EVO_GHOST_DSN'},
    $ENV{'B2EVO_GHOST_USERNAME'},
    $ENV{'B2EVO_GHOST_PASSWORD'},
);
my @ghost_posts;
my $evo_items = get_evo_items();

foreach my $item (@$evo_items) {
    my $content = $item->{'post_content'} // '';
    my $format = 'plaintext';
    if ( $content =~ m{</\w+>} ) {
        $format = 'html';
    }
    if ( $format eq 'plaintext' ) {
        $content = text2html($content);
    }
    push @ghost_posts, {
        'type'         => 'post',
        'status'       => 'published',
        'created_at'   => scalar evo2ghost_ts( $item->{'post_datecreated'} ),
        'updated_at'   => scalar evo2ghost_ts( $item->{'post_datemodified'} ),
        'published_at' => scalar evo2ghost_ts( $item->{'post_datecreated'} ),
        'title'        => scalar $item->{'post_title'},
        'slug'         => scalar $item->{'post_urltitle'},
        'html'         => scalar $content,
    }
}

my $ds = {
    'db' => [
        {
            'meta' => {
                'exported_on' => scalar time,
                'version'     => '5.38.0',
            },
            'data' => {
                'posts' => \@ghost_posts,
            }
        }
    ],
};

print $coder->encode($ds);

$dbh->disconnect();

exit;

sub get_evo_items {
    return sql('SELECT * FROM evo_items__item WHERE post_ityp_ID=1 ORDER BY post_ID');
}

sub sql {
    my ($query, @args) = @_;
    my $sth = $dbh->prepare($query) or die "prepare statement '$query' failed: $dbh->errstr()";
    $sth->execute(@args) or die "execution with '@args' failed: $dbh->errstr()";
    my $data = $sth->fetchall_arrayref({});
    $sth->finish();
    return $data;
}

sub evo2ghost_ts {
    my ($evo_ts) = @_;
    my $dt = $strp->parse_datetime($evo_ts);
    $dt->set_time_zone('UTC');
    return $iso8601->format_datetime($dt);
}

sub text2html {
    my ($text) = @_;
    my $html = $t2h->parse($text);
    $html =~ s/\r\n/<br>\n/g;
    return $html;
}
