#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Dotenv -load;
use DBI ();
use JSON ();
use BSON::Types qw(bson_oid);
use Data::UUID ();
use DateTime::Format::ISO8601 ();
use DateTime ();
use HTML::FromText ();

my $coder = JSON->new->pretty->canonical;
my $ug = Data::UUID->new();
my $strp = DateTime::Format::Strptime->new(
    'pattern'   => '%F %T',
    'time_zone' => $ENV{'B2EVO_TIMEZONE'} // 'UTC',
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
    $ENV{'B2EVO_DSN'},
    $ENV{'B2EVO_DSN_USERNAME'},
    $ENV{'B2EVO_DSN_PASSWORD'},
);

# Fetch all b2evo tags and build array + map
my $evo_tags = get_evo_tags();
my $evo_tag_id_map = {};
my @ghost_tags;
foreach my $tag (@$evo_tags) {
    my $evo_tag_id = $tag->{'tag_ID'};
    my $tag_id = bson_oid()->hex();
    $evo_tag_id_map->{ $evo_tag_id } = $tag_id;
    push @ghost_tags, {
        'id'   => scalar $tag_id,
        'name' => scalar $tag->{'tag_name'},
        'slug' => scalar lc( $tag->{'tag_name'} =~ s/[^a-zA-Z0-9]/-/gr ),
    };
}

# Fetch all b2evo posts and build array + map
my $evo_items = get_evo_items();
my $evo_item_id_map = {};
my $ghost_tag_slug_map = {};
my @ghost_posts;
foreach my $item (@$evo_items) {
    my $content = $item->{'post_content'} // '';
    my $format = 'plaintext';
    if ( $content =~ m{</\w+>} ) {
        $format = 'html';
    }
    if ( $format eq 'plaintext' ) {
        $content = text2html($content);
    }
    $content = cleanup_content($content);
    my $evo_item_id = $item->{'post_ID'};
    my $post_id = bson_oid()->hex();
    my $post_uuid = lc( $ug->create_str() );
    $evo_item_id_map->{ $evo_item_id } = $post_id;
    push @ghost_posts, {
        'type'         => 'post',
        'status'       => 'published',
        'id'           => scalar $post_id,
        'uuid'         => scalar $post_uuid,
        'created_at'   => scalar evo2ghost_ts( $item->{'post_datecreated'} ),
        'updated_at'   => scalar evo2ghost_ts( $item->{'post_datemodified'} ),
        'published_at' => scalar evo2ghost_ts( $item->{'post_datecreated'} ),
        'title'        => scalar $item->{'post_title'},
        'slug'         => scalar $item->{'post_urltitle'},
        'html'         => scalar $content,
    };
    # Store the b2evo locale as a tag with the lang- prefix
    # You'll need to manually give these language tags useful tag names after the import
    {
        my $tag_slug = 'lang-' . lc( $item->{'post_locale'} ); # syntax b2evo: 'nb-NO'
        my $tag_name = 'Language: ' . $item->{'loc_name'} =~ s/\Q&aring;\E/å/r;
        # TODO: Fix utf8 issues
        my $tag_slug_detail_map = $ghost_tag_slug_map->{ $tag_slug } // {};
        my $tag_slug_post_ids = $tag_slug_detail_map->{'posts'} // [];
        push @$tag_slug_post_ids, $post_id;
        $tag_slug_detail_map->{'id'} //= bson_oid()->hex();
        $tag_slug_detail_map->{'name'} //= $tag_name;
        $tag_slug_detail_map->{'sort_order'} //= 3;
        $tag_slug_detail_map->{'posts'} = $tag_slug_post_ids;
        $ghost_tag_slug_map->{ $tag_slug } = $tag_slug_detail_map;
    }
    # Store the b2evo main category as a tag with the category- prefix
    {
        my $tag_slug = $item->{'cat_urlname'};
        my $tag_name = $item->{'cat_name'};
        my $tag_desc = $item->{'cat_description'};
        my $tag_slug_detail_map = $ghost_tag_slug_map->{ $tag_slug } // {};
        my $tag_slug_post_ids = $tag_slug_detail_map->{'posts'} // [];
        push @$tag_slug_post_ids, $post_id;
        $tag_slug_detail_map->{'id'} //= bson_oid()->hex();
        $tag_slug_detail_map->{'name'} //= $tag_name;
        $tag_slug_detail_map->{'desc'} //= $tag_desc;
        $tag_slug_detail_map->{'sort_order'} //= 0;
        $tag_slug_detail_map->{'posts'} = $tag_slug_post_ids;
        $ghost_tag_slug_map->{ $tag_slug } = $tag_slug_detail_map;
    }
}

# Fetch all additional post category tags and add them to tag slug map
my $evo_item_categories = get_evo_item_categories();
foreach my $cat (@$evo_item_categories) {
    my $post_id = $evo_item_id_map->{ $cat->{'post_ID'} };
    my $tag_slug = $cat->{'cat_urlname'};
    my $tag_name = $cat->{'cat_name'};
    my $tag_desc = $cat->{'cat_description'};
    my $tag_slug_detail_map = $ghost_tag_slug_map->{ $tag_slug } // {};
    my $tag_slug_post_ids = $tag_slug_detail_map->{'posts'} // [];
    push @$tag_slug_post_ids, $post_id;
    $tag_slug_detail_map->{'id'} //= bson_oid()->hex();
    $tag_slug_detail_map->{'name'} //= $tag_name;
    $tag_slug_detail_map->{'desc'} //= $tag_desc;
    $tag_slug_detail_map->{'sort_order'} //= 1;
    $tag_slug_detail_map->{'posts'} = $tag_slug_post_ids;
    $ghost_tag_slug_map->{ $tag_slug } = $tag_slug_detail_map;
}

# Fetch all b2evo post tags and build array
my $evo_item_tags = get_evo_item_tags();
my @ghost_posts_tags;
foreach my $item_tag (@$evo_item_tags) {
    my $item_id = $item_tag->{'itag_itm_ID'};
    my $tag_id = $item_tag->{'itag_tag_ID'};
    push @ghost_posts_tags, {
        'post_id'    => scalar $evo_item_id_map->{ $item_id },
        'tag_id'     => scalar $evo_tag_id_map->{ $tag_id },
        'sort_order' => 2,
    };
}

# Append all tags in tag slug map into tags and post tags arrays
foreach my $tag_slug (keys %$ghost_tag_slug_map) {
    my $tag_slug_detail_map = $ghost_tag_slug_map->{ $tag_slug };
    my $tag_id = $tag_slug_detail_map->{'id'};
    push @ghost_tags, {
        'id'          => scalar $tag_id,
        'slug'        => scalar $tag_slug,
        'name'        => scalar $tag_slug_detail_map->{'name'},
        'description' => scalar $tag_slug_detail_map->{'desc'},
    };
    my $post_ids = $tag_slug_detail_map->{'posts'};
    foreach my $post_id (@$post_ids) {
        push @ghost_posts_tags, {
            'post_id'    => scalar $post_id,
            'tag_id'     => scalar $tag_id,
            'sort_order' => scalar $tag_slug_detail_map->{'sort_order'},
        };
    }
}

# Build final Ghost import data structure
my $ds = {
    'db' => [
        {
            'meta' => {
                'exported_on' => scalar time,
                'version'     => '5.53.1',
            },
            'data' => {
                'posts'      => \@ghost_posts,
                'posts_tags' => \@ghost_posts_tags,
                'tags'       => \@ghost_tags,
            }
        }
    ],
};

print $coder->encode($ds);

$dbh->disconnect();

exit;

sub get_evo_items {
    return sql(<<'EOM');
SELECT i.*,c.*,l.loc_name
FROM evo_items__item i
 LEFT JOIN evo_categories c ON i.post_main_cat_ID = c.cat_ID
 LEFT JOIN evo_locales l ON i.post_locale = l.loc_locale
WHERE i.post_ityp_ID=1
ORDER BY i.post_ID
EOM
}

sub get_evo_item_categories {
    return sql(<<'EOM');
SELECT
 i.post_ID,
 c.cat_name,
 c.cat_urlname,
 c.cat_description
FROM evo_items__item i
 LEFT JOIN evo_postcats pc ON i.post_ID = pc.postcat_post_ID
 LEFT JOIN evo_categories c ON pc.postcat_cat_ID = c.cat_ID
ORDER BY i.post_ID, c.cat_ID
EOM
}

sub get_evo_tags {
    return sql(<<'EOM');
SELECT *
FROM evo_items__tag
ORDER BY tag_ID
EOM
}

sub get_evo_item_tags {
    return sql(<<'EOM');
SELECT *
FROM evo_items__itemtag
ORDER BY itag_itm_ID, itag_tag_ID
EOM
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

sub cleanup_content {
    my ($html) = @_;
    $html =~ s{\Q/media/blogs/all/\E}{/content/images/}g; # make image links relative
    $html =~ s{\Qhttp://blog.robin.smidsrod.no/index.php/\E}{/}g; # make self-referential links relative
    $html =~ s{\Qhttp://blog.robin.smidsrod.no/\E}{/}g; # make site links relative
    $html =~ s{\Qhttp://blog.robin.smidsrod.no\E}{/}g; # make site links relative
    return $html;
}
