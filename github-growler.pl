#!/usr/bin/perl
use strict;
use warnings;
use 5.008001;

use FindBin;
use lib "$FindBin::Bin/lib";
use local::lib "$FindBin::Bin/extlib";

use Config::IniFiles;
use Encode;
use Cocoa::Growl ':all';
use File::Copy;
use File::Path;
use LWP::Simple;
use URI;
use XML::LibXML;
use Storable;
use Cocoa::EventLoop;


our $VERSION = "1.05";

my %events = (
    "New Commits" => qr/(?:pushed to|committed to)/,
    "New Repository" => qr/created repository/,
    "Forked Repository" => qr/forked (?!gist:)/,
    "New Branch" => qr/created branch/,
    "New Gist" => qr/created gist:/,
    "Updated Gist" => qr/updated gist:/,
    "Forked Gist" => qr/forked gist:/,
    "Watching Project" => qr/started watching/,
    "Following People" => qr/started following/,
    "New Issue" => qr/opened issue/,
    "Closed Issue" => qr/closed issue/,
);

my $AppDomain = "net.bulknews.GitHubGrowler";

my $AppName = "Github Growler";
my @events  = ((keys %events), "Misc");

my $TempDir = "$ENV{HOME}/Library/Caches/$AppDomain";
mkdir $TempDir, 0777 unless -e $TempDir;

my $AppIcon = "$TempDir/octocat.png";
copy "$FindBin::Bin/data/octocat.png", $AppIcon;

growl_register(
    app           => $AppName,
    icon          => $AppIcon,
    notifications => \@events,
);

my $Cache = sub {
    my($key, $code) = @_;
    $key = lc $key;
    $key =~ s/[^a-z0-9]+/_/g;
    my $path = "$TempDir/$key";

    if (-f $path) {
        my $age = time - (stat($path))[10];
        if ($age < 60*60*24) {
            my $value = Storable::retrieve($path);
            return $value->{value};
        } else {
            unlink $path;
        }
    }

    my $data = $code->();
    Storable::nstore({ value => $data }, $path);
    return $data;
};

my %Seen;

my %options = (interval => 300, maxGrowls => 10);
get_preferences(\%options, "interval", "maxGrowls");
my @args = @ARGV == 2 ? @ARGV : get_github_token();


my $t;
my $cb; $cb = sub {
    growl_feed(@args);
    $t = Cocoa::EventLoop->timer(
        after => $options{interval},
        cb    => $cb,
    );
};
$cb->();

Cocoa::EventLoop->run;

sub get_preferences {
    my($opts, @keys) = @_;

    for my $key (@keys) {
        my $value = read_preference($key);
        $opts->{$key} = $value if defined $value;
    }
}

sub read_preference {
    my $key = shift;

    no warnings 'once';
    open OLDERR, ">&STDERR";
    open STDERR, ">/dev/null";
    my $value = `defaults read $AppDomain $key`;
    open STDERR, ">&OLDERR";

    return if $value eq '';
    chomp $value;
    return $value;
}

sub die_notice {
    my $msg = shift;
    growl_notify(
        name        => 'Fatal Error',
        title       => $AppName,
        description => $msg,
    );
    die $msg;
}

sub get_github_token {
    my($user, $token);

    eval {
        my $config = Config::IniFiles->new(-file => "$ENV{HOME}/.gitconfig");
        $user  = $config->val('github', 'user');
        $token = $config->val('github', 'token');
    };
        
    unless ($user && $token) {
        die_notice("GitHub config not found: See http://github.com/guides/local-github-config and set them");
    }

    return ($user, $token);
}

sub growl_feed {
    my($user, $token) = @_;

    my @feeds = (
        "http://github.com/$user.private.atom?token=$token",
        "http://github.com/$user.private.actor.atom?token=$token",
    );

    my $get_value = sub {
        my($entry, $tag) = @_;
        my($node) = $entry->getElementsByTagName($tag);
        return $node ? $node->textContent : "";
    };

    my $get_attr = sub {
        my ($entry, $tag, $attr) = @_;
        my ($node) = $entry->getElementsByTagName($tag);
        return $node ? $node->getAttribute($attr) : "";
    };

    for my $uri (@feeds) {
        my $doc = eval { XML::LibXML->new->parse_string(LWP::Simple::get($uri)) };
        unless ($doc) {
            growl_notify(
                name        => 'Error',
                title       => $AppName,
                description => "Can't parse the feed $uri",
            );
            next;
        }

        my @to_growl;
        for my $entry ($doc->getElementsByTagName('entry')) {
            my $id = $get_value->($entry, 'id');
            next if $Seen{$id}++;
            my $author = $get_value->($entry, 'name');
            my $user = get_user($author);
            $user->{name} ||= $author;
            my $link = $get_attr->($entry, 'link', 'href');
            push @to_growl, { entry => $entry, user => $user, link => $link };
        }

        my $i;
        for my $stuff (@to_growl) {
            my($event, $title, $description, $icon, $last);
            if ($i++ >= $options{maxGrowls}) {
                my %uniq;
                $event = "Misc";
                $title = (@to_growl - $options{maxGrowls}) . " more updates";
                my @who = grep !$uniq{$_}++, map $_->{user}{name}, @to_growl[$i..$#to_growl];
                $description = "From ";
                if (@who > 1) {
                    $description .= join ", ", @who[0..$#who-1];
                    $description .= " and " . $who[-1];
                } else {
                    $description .= "$who[0]";
                }
                $icon = $AppIcon;
                $last = 1;
            } else {
                my $body = munge_update_body($get_value->($stuff->{entry}, 'content'));
                $event = get_event_type($get_value->($stuff->{entry}, 'title'));
                $title = $stuff->{user}{name};
                $description  = $get_value->($stuff->{entry}, 'title');
                $description .= ": $body" if $body;
                $icon = $stuff->{user}{avatar} ? "$stuff->{user}{avatar}" : $AppIcon;
            }

            growl_notify(
                name        => $event,
                title       => encode_utf8($title),
                description => encode_utf8($description),
                icon        => $icon,
                on_click    => sub {
                    system 'open', $stuff->{link}
                        if $stuff->{link};
                },
            );

            last if $last;
        }
    }
}

sub munge_update_body {
    use Web::Scraper;
    my $content = shift;
    my $res = scraper { process "div.message", message => 'TEXT' }->scrape($content);
    $res->{message} =~ s/^\s*[0-9a-f]{40}\s*//; # strip SHA1
    return $res->{message};
}

sub get_event_type {
    my $title = shift;

    for my $type (keys %events) {
        my $re = $events{$type};
        return $type if $title =~ $re;
    }

    return "Misc";
}

sub get_user {
    my $name = shift;
    $Cache->("user:$name", sub {
        use Web::Scraper;
        my $scraper = scraper {
            process ".fn", name => 'TEXT';
            process ".avatared img", avatar => [ '@src', sub {
                my $suffix = (split(/\./, $_))[-1];
                my $path = "$TempDir/$name.$suffix";
                LWP::Simple::mirror($_, $path);
                return $path;
            } ];
        };

        return eval { $scraper->scrape(URI->new("http://github.com/$name")) } || {};
    });
}

__END__

=head1 NAME

github-growler

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 LICENSE

This program is licensed under the same terms as Perl itself.

=cut
