#!/usr/bin/env perl

use strict;
use warnings;

use Dotenv -load;
use DBI ();
use JSON ();
use BSON::Types qw(bson_oid);
use Data::UUID ();
use DateTime::Format::ISO8601 ();
use DateTime ();
use HTML::FromText ();

my $coder = JSON->new->canonical;
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

my $ghost_dbh = DBI->connect(
    $ENV{'GHOST_DSN'},
    $ENV{'GHOST_DSN_USERNAME'},
    $ENV{'GHOST_DSN_PASSWORD'},
);

# Fetch all ghost posts slugs and build map
my $ghost_posts = get_ghost_posts();
my $ghost_post_slug_map = {};
foreach my $post (@$ghost_posts) {
    $ghost_post_slug_map->{ $post->{'slug'} } = $post->{'id'};
}

# Fetch all b2evo authors, create members in ghost and build map
my $evo_members = get_evo_members();
my $ghost_member_email_map = {};
foreach my $member (@$evo_members) {
    my $email = $member->{'email'};
    next unless $email;
    next if $ghost_member_email_map->{$email}; # skip already imported
    my $name = $member->{'name'};
    next unless $name;
    #next if $name =~ /(?:http|www|\.com|deal|product|paris|hotel|socks|shirt|design|girls|blocker|penis|android|cheat|review|free|web|__|[?!])/i;
    next if $email =~ /(?:[0-9]{5,})/i;
    my $id = bson_oid()->hex();
    my $created_at = evo2ghost_ts( $member->{'comment_date'} );
    print "member: id=$id email=$email name=$name\n";
    ghost_do(<<'EOM', $id, $email, $name, $created_at);
INSERT IGNORE INTO members SET
 id         = ?,
 email      = ?,
 name       = ?,
 created_at = ?,
 created_by         = 1,
 status             = 'free',
 email_count        = 0,
 email_opened_count = 0,
 enable_comment_notifications = 0
EOM
    $ghost_member_email_map->{ $email } = $id;
}

# Fetch all b2evo comments and build array
my $evo_comments = get_evo_comments();
foreach my $comment (@$evo_comments) {
    my $email = $comment->{'email'};
    my $evo_slug = $comment->{'post_urltitle'};
    my $ghost_post_id = $ghost_post_slug_map->{ $evo_slug };
    my $ghost_member_id = $ghost_member_email_map->{ $email };
    next unless $ghost_member_id;
    
    my $content = $comment->{'comment_content'} // '';
    my $format = 'plaintext';
    if ( $content =~ m{</\w+>} ) {
        $format = 'html';
    }
    if ( $format eq 'plaintext' ) {
        $content = text2html($content);
    }

    my $id = bson_oid()->hex();
    my $created_at = evo2ghost_ts( $comment->{'comment_date'} ) =~ s/Z$//r;
    my $updated_at = evo2ghost_ts( $comment->{'comment_last_touched_ts'} ) =~ s/Z$//r;
    my $ds = {
        'id'         => scalar $id,
        'post_id'    => scalar $ghost_post_id,
        'member_id'  => scalar $ghost_member_id,
        'status'     => 'published',
        'html'       => scalar $content,
        'created_at' => scalar $created_at,
        'updated_at' => scalar $updated_at, 
    };

    print "comment: " . $coder->encode($ds);
    ghost_do(<<'EOM', $id, $ghost_post_id, $ghost_member_id, $content, $created_at, $updated_at);
INSERT INTO comments SET
 id         = ?,
 post_id    = ?,
 member_id  = ?,
 html       = ?,
 created_at = ?,
 updated_at = ?,
 status     = 'published'
EOM
}

# Fetch all b2evo links and replace the navigation
my $evo_links = get_evo_links();
my @ghost_nav_links = ({
    'label' => 'Home',
    'url'   => '/',
});
foreach my $link (@$evo_links) {
    push @ghost_nav_links, {
        'label' => scalar $link->{'post_title'},
        'url'   => scalar $link->{'post_url'},
    }
}
my $ghost_nav_json = $coder->encode(\@ghost_nav_links);
print "navigation: $ghost_nav_json\n";
ghost_do(<<'EOM', $ghost_nav_json );
UPDATE settings SET
 value = ?,
 updated_at = CURRENT_TIMESTAMP
WHERE `group` = 'site'
  AND `key` = 'navigation'
EOM

$ghost_dbh->disconnect();
$dbh->disconnect();

exit;

sub get_evo_comments {
    return sql(<<'EOM');
SELECT
 c.*,
 i.post_urltitle,
 coalesce(comment_author_email, u.user_email) AS email
FROM evo_comments c
 LEFT JOIN evo_items__item i ON c.comment_item_ID = i.post_ID
 LEFT JOIN evo_users u ON c.comment_author_user_ID = u.user_ID
WHERE c.comment_type = 'comment'
 AND c.comment_status = 'published'
ORDER BY c.comment_ID
EOM
}

sub get_evo_members {
    return sql(<<'EOM');
SELECT DISTINCTROW
 coalesce(c.comment_author, concat(u.user_firstname, ' ', u.user_lastname)) AS name,
 coalesce(c.comment_author_email, u.user_email) AS email,
 c.comment_date
FROM evo_comments c
 LEFT JOIN evo_users u ON c.comment_author_user_ID = u.user_ID
ORDER BY c.comment_date ASC
EOM
}

sub get_ghost_posts {
    return ghost_sql(<<'EOM');
SELECT id, slug, comment_id
FROM posts
ORDER BY id
EOM
}

sub get_evo_links {
    return sql(<<'EOM');
SELECT post_title, post_url
FROM evo_items__item
WHERE post_ityp_ID = 3000
ORDER BY post_ID
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

sub ghost_sql {
    my ($query, @args) = @_;
    my $sth = $ghost_dbh->prepare($query) or die "prepare statement '$query' failed: $ghost_dbh->errstr()";
    $sth->execute(@args) or die "execution with '@args' failed: $ghost_dbh->errstr()";
    my $data = $sth->fetchall_arrayref({});
    $sth->finish();
    return $data;
}

sub ghost_do {
    my ($query, @args) = @_;
    my $sth = $ghost_dbh->prepare($query) or die "prepare statement '$query' failed: $ghost_dbh->errstr()";
    $sth->execute(@args) or die "execution with '@args' failed: $ghost_dbh->errstr()";
    my $data = $sth->rows;
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
